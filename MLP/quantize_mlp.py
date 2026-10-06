"""Post-training quantization for the supplied train_mlp.py (784 -> 16 -> 10).
Run beside train_mlp.py. Integer inference itself only requires NumPy.
"""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np

ROOT = Path(__file__).resolve().parent
I32_MAX = 2**31 - 1


def round_away(x):
    """Offline parameter rounding: nearest, ties away from zero."""
    return np.sign(x) * np.floor(np.abs(x) + 0.5)


def weight_quant(w):
    scale = float(np.max(np.abs(w))) / 127.0
    scale = scale if scale > 0 else 1.0
    return np.clip(round_away(w / scale), -127, 127).astype(np.int8), scale


def bias_quant(b, scale):
    q = round_away(b / scale)
    if not np.isfinite(q).all() or np.any(np.abs(q) > I32_MAX):
        raise ValueError('Bias cannot safely fit INT32 at this scale.')
    return q.astype(np.int32)


def accumulator_bound(w, b, input_max):
    # Absolute bound covers every partial sum as well as the final sum.
    bound = input_max * np.abs(w.astype(np.int64)).sum(axis=1)
    bound += np.abs(b.astype(np.int64))
    if bound.max() > I32_MAX:
        raise ValueError('Accumulator bound exceeds INT32.')
    return int(bound.max())


def multiplier_shift(ratio):
    for shift in range(30, 0, -1):
        mult = int(np.floor(ratio * (1 << shift) + 0.5))
        if 1 <= mult <= I32_MAX:
            return mult, shift
    raise ValueError('Cannot represent requantization ratio with this format.')


def integer_inference(images, params):
    """Return FC1 accumulators, hidden INT8, FC2 logits and class.

    Stored accumulators are INT32. NumPy calculates in INT64 as a checked
    reference; static bounds prove that FC dot products fit INT32.
    Requantization intentionally uses a wide INT64 multiply.
    """
    images = np.asarray(images)
    if images.dtype != np.uint8:
        raise TypeError('Expected raw UINT8 pixels, not normalized pixels.')
    x = images.reshape(-1, 784).astype(np.int64)
    acc1 = x @ params['w1'].astype(np.int64).T + params['b1']
    if np.any(np.abs(acc1) > I32_MAX):
        raise OverflowError('FC1 INT32 overflow')
    positive = np.maximum(acc1, 0)
    mult, shift = int(params['mult']), int(params['shift'])
    hidden_wide = (positive * mult + (1 << (shift - 1))) >> shift
    hidden = np.clip(hidden_wide, 0, 127).astype(np.int8)
    acc2 = hidden.astype(np.int64) @ params['w2'].astype(np.int64).T
    acc2 += params['b2']
    if np.any(np.abs(acc2) > I32_MAX):
        raise OverflowError('FC2 INT32 overflow')
    return (acc1.astype(np.int32), hidden, acc2.astype(np.int32),
            np.argmax(acc2, axis=1))


def integer_predictions(images, params):
    return np.concatenate([
        integer_inference(images[i:i + 256], params)[3]
        for i in range(0, len(images), 256)
    ])


def main():
    import torch
    from torch.utils.data import random_split
    from torchvision.datasets import MNIST
    from train_mlp import MLP

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint', type=Path,
                        default=ROOT / 'outputs/run1/mlp_best.pt')
    parser.add_argument('--data-dir', type=Path, default=ROOT / 'data')
    parser.add_argument('--out', type=Path, default=ROOT / 'outputs/int8_run1')
    args = parser.parse_args()
    if args.out.resolve() == args.checkpoint.resolve().parent:
        raise ValueError('Choose a separate output directory for quantization.')
    if args.out.exists() and any(args.out.iterdir()):
        raise ValueError('Output directory is not empty. Choose a new --out.')

    checkpoint = torch.load(args.checkpoint, map_location='cpu', weights_only=True)
    config = checkpoint['config']
    for key, expected in [('input_size', 784), ('hidden_size', 16),
                          ('output_size', 10), ('input_preprocessing', 'pixel / 255'),
                          ('flatten_order', 'row_major')]:
        if config.get(key) != expected:
            raise ValueError(f'Unexpected config {key}: {config.get(key)}')
    seed = int(config['seed'])
    model = MLP().cpu().eval()
    model.load_state_dict(checkpoint['model_state_dict'], strict=True)
    state = {k: v.detach().cpu().numpy().astype(np.float64)
             for k, v in model.state_dict().items()}
    if not all(np.isfinite(v).all() for v in state.values()):
        raise ValueError('Checkpoint contains non-finite parameters.')

    dataset = MNIST(str(args.data_dir), train=True, download=True)
    training, validation = random_split(
        dataset, [54000, 6000], generator=torch.Generator().manual_seed(seed))
    train_ids = np.asarray(training.indices, dtype=np.int64)
    val_ids = np.asarray(validation.indices, dtype=np.int64)
    raw = dataset.data.numpy()
    labels = dataset.targets.numpy()
    print(f'Split recreated: train={len(train_ids)}, validation={len(val_ids)}, seed={seed}')

    @torch.inference_mode()
    def baseline_predictions(images):
        result = []
        for i in range(0, len(images), 256):
            x = torch.from_numpy(images[i:i + 256].copy()).float() / 255.0
            result.append(model(x).argmax(1).numpy())
        return np.concatenate(result)

    # Calibration uses only the original 54,000 training images.
    hidden_values = []
    with torch.inference_mode():
        for start in range(0, len(train_ids), 256):
            x = torch.from_numpy(raw[train_ids[start:start + 256]].copy()).float() / 255.0
            h = model.relu(model.fc1(model.flatten(x)))
            hidden_values.append(h.numpy())
    hidden_values = np.concatenate(hidden_values).astype(np.float64)

    w1, sw1 = weight_quant(state['fc1.weight'])
    w2, sw2 = weight_quant(state['fc2.weight'])
    sx = 1.0 / 255.0
    b1 = bias_quant(state['fc1.bias'], sx * sw1)
    bound1 = accumulator_bound(w1, b1, 255)

    # Fixed candidate list chosen before inspecting test results.
    # Ties prefer the first candidate (less clipping).
    candidates = []
    best = None
    val_images = raw[val_ids]
    for percentile in (100.0, 99.9, 99.5):
        threshold = float(np.percentile(hidden_values, percentile))
        if threshold <= 0:
            threshold = float(hidden_values.max()) or 1.0
        sh = threshold / 127.0
        mult, shift = multiplier_shift(sx * sw1 / sh)
        b2 = bias_quant(state['fc2.bias'], sh * sw2)
        bound2 = accumulator_bound(w2, b2, 127)
        params = dict(w1=w1, b1=b1, w2=w2, b2=b2,
                      mult=np.int32(mult), shift=np.int32(shift))
        pred = integer_predictions(val_images, params)
        correct = int((pred == labels[val_ids]).sum())
        row = dict(percentile=percentile, hidden_threshold=threshold,
                   hidden_scale=sh, mult=mult, shift=shift,
                   validation_correct=correct,
                   validation_accuracy_percent=100.0 * correct / len(val_ids),
                   accumulator_bound_fc1=bound1, accumulator_bound_fc2=bound2)
        candidates.append(row)
        print(f'Calibration percentile={percentile}: validation={row["validation_accuracy_percent"]:.2f}%')
        if best is None or correct > best[0]:
            best = correct, params, row
    _, params, selected = best
    print(f'Selected percentile: {selected["percentile"]}')

    # Only now access test data; test does not select scales/candidates.
    test = MNIST(str(args.data_dir), train=False, download=True)
    test_images, test_labels = test.data.numpy(), test.targets.numpy()
    baseline = baseline_predictions(test_images)
    integer = integer_predictions(test_images, params)
    base_acc = float((baseline == test_labels).mean() * 100)
    int_acc = float((integer == test_labels).mean() * 100)
    agreement = float((baseline == integer).mean() * 100)
    print(f'Baseline test accuracy: {base_acc:.2f}%')
    print(f'Integer test accuracy:  {int_acc:.2f}%')
    print(f'Change: {int_acc - base_acc:+.2f} percentage points')
    print(f'Prediction agreement: {agreement:.2f}%')

    args.out.mkdir(parents=True, exist_ok=True)
    np.savez(args.out / 'mlp_int8.npz', **params)
    # Reload exported parameters and check actual serialization round-trip.
    with np.load(args.out / 'mlp_int8.npz', allow_pickle=False) as archive:
        reloaded = {k: archive[k] for k in archive.files}
    acc1, hidden, logits, classes = integer_inference(test_images[:100], reloaded)
    if not np.array_equal(classes, integer[:100]):
        raise AssertionError('Reloaded integer parameters produced different predictions.')
    np.savez(args.out / 'reference_vectors.npz', images=test_images[:100],
             labels=test_labels[:100], acc1=acc1, hidden=hidden,
             logits=logits, predictions=classes)
    np.savez(args.out / 'split_indices.npz', train=train_ids, validation=val_ids)
    report = dict(
        checkpoint_sha256=hashlib.sha256(args.checkpoint.read_bytes()).hexdigest(),
        seed=seed, torch_version=str(torch.__version__), numpy_version=np.__version__,
        architecture=[784, 16, 10], input_scale=sx, weight1_scale=sw1,
        weight2_scale=sw2, bias1_scale=sx * sw1,
        bias2_and_logits_scale=selected['hidden_scale'] * sw2,
        zero_points=0, candidates=candidates, selected=selected,
        baseline_test_accuracy_percent=base_acc, integer_test_accuracy_percent=int_acc,
        change_percentage_points=int_acc - base_acc,
        prediction_agreement_percent=agreement,
        parameter_rounding='nearest; ties away from zero',
        requantization='clip((max(acc1,0)*mult + 2**(shift-1)) >> shift, 0, 127)',
        requantization_product_dtype='int64', argmax_tie='first index',
        weight_layout='out_features,in_features; row-major')
    (args.out / 'quantization_report.json').write_text(
        json.dumps(report, indent=2), encoding='utf-8')
    for i in range(10):
        print(f'Sample {i}: label={test_labels[i]}, baseline={baseline[i]}, integer={integer[i]}')
    print(f'Saved integer model, report, splits and 100 reference vectors: {args.out.resolve()}')


if __name__ == '__main__':
    main()
