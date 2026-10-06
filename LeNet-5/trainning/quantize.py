"""Stage 3 PTQ: train-only calibration, validation selection, integer full test."""
import argparse
import csv
import json
import shutil
import time
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import DataLoader, TensorDataset
from torchvision.datasets import MNIST

from lenet5.common import (ROOT, dataset_hashes, environment, fresh_directory,
                           protected_hashes, setup_runtime, sha, source_hashes,
                           timestamp, write_json)
from lenet5.data import DATA_DIR, PREPROCESSING, preprocess
from lenet5.evaluate import collect
from lenet5.integer import (I32_MIN, I32_MAX, LAYERS, SHAPES, inference, load_model,
                            model_bounds, ratio_multiplier, round_away, run_dataset,
                            self_check)
from lenet5.model import LeNet5B, MODEL_ID, PARAMETERS

DEFAULT_FLOAT = ROOT / "outputs/lenet5/float_20260930_142800_567918"
PERCENTILES = (99., 99.5, 99.9, 100.)
RELU_NAMES = {"relu1": "c1", "relu3": "c3", "relu5": "c5", "relu6": "f6"}


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def float_run_hashes(run):
    return {str(p.relative_to(run)).replace("\\", "/"): sha(p)
            for p in sorted(run.rglob("*")) if p.is_file()}


def verify_float(run):
    config = read_json(run / "config.json")
    checkpoint = run / "lenet5_best.pt"
    ckpt = torch.load(checkpoint, map_location="cpu", weights_only=True)
    assert ckpt["epoch"] == 8 and ckpt["config"] == config
    assert config["model_id"] == MODEL_ID and config["preprocessing"] == PREPROCESSING
    assert dataset_hashes() == config["dataset_sha256"]
    for name, digest in config["source_sha256"].items():
        assert sha(ROOT / "lenet5" / name) == digest
        assert sha(run / "source" / name) == digest
    assert sha(checkpoint) == read_json(run / "test_eval/metrics.json")["checkpoint_sha256"]
    model = LeNet5B().eval()
    model.load_state_dict(ckpt["model_state_dict"], strict=True)
    assert isinstance(model.layers.c5, torch.nn.Conv2d)
    assert sum(p.numel() for p in model.parameters()) == PARAMETERS
    description = model.parameter_description()
    assert description == read_json(run / "parameters.json")
    with np.load(run / "split_indices.npz", allow_pickle=False) as file:
        train, validation = file["train"].copy(), file["validation"].copy()
        assert int(file["seed"]) == config["seed"]
    assert len(train) == 54000 and len(validation) == 6000
    assert np.array_equal(np.sort(np.concatenate([train, validation])), np.arange(60000))
    permutation = torch.randperm(60000, generator=torch.Generator().manual_seed(config["seed"])).numpy()
    assert np.array_equal(train, permutation[:54000]) and np.array_equal(validation, permutation[54000:])
    return model, train, validation, dict(passed=True, epoch=8, parameter_count=PARAMETERS,
            c5_convolution=True, source_dataset_checkpoint_hashes_match=True,
            split_matches_stage2=True, checkpoint_sha256=sha(checkpoint),
            float_source_sha256=config["source_sha256"])


@torch.inference_mode()
def calibrate(model, images):
    values = {layer: [] for layer in RELU_NAMES.values()}
    for start in range(0, len(images), 128):
        x = preprocess(torch.from_numpy(images[start:start+128]))
        for name, module in model.layers.named_children():
            x = module(x)
            if name in RELU_NAMES:
                values[RELU_NAMES[name]].append(x.numpy().copy().reshape(-1))
    stats = {}
    for layer, batches in values.items():
        array = np.concatenate(batches)
        assert np.isfinite(array).all() and array.min() >= 0
        thresholds = np.percentile(array, PERCENTILES, method="linear")
        stats[layer] = dict(count=len(array), minimum=float(array.min()), maximum=float(array.max()),
            mean=float(array.mean(dtype=np.float64)), zero_count=int(np.count_nonzero(array == 0)),
            percentiles={str(p): float(v) for p, v in zip(PERCENTILES, thresholds)},
            tensor="Float activation after ReLU, before max pool (where applicable)",
            percentile_method="NumPy linear; all elements, including zeros")
    return stats


def build_candidate(model, calibration, percentile):
    params, rows = {}, []
    state = model.state_dict()
    input_scale = 1 / 255
    for layer in LAYERS:
        w = state[f"layers.{layer}.weight"].numpy().astype(np.float64)
        b = state[f"layers.{layer}.bias"].numpy().astype(np.float64)
        assert np.isfinite(w).all() and np.isfinite(b).all()
        weight_scale = float(np.abs(w).max()) / 127 or 1.0
        qw = np.clip(round_away(w / weight_scale), -127, 127).astype(np.int8)
        bias_scale = input_scale * weight_scale
        qb_wide = round_away(b / bias_scale)
        if not np.isfinite(qb_wide).all() or qb_wide.min() < I32_MIN or qb_wide.max() > I32_MAX:
            raise OverflowError(f"{layer} bias not INT32")
        params.update({f"{layer}_weight": qw, f"{layer}_bias": qb_wide.astype(np.int32),
                       f"{layer}_input_scale": np.array(input_scale, np.float64),
                       f"{layer}_weight_scale": np.array(weight_scale, np.float64),
                       f"{layer}_accumulator_scale": np.array(bias_scale, np.float64)})
        row = dict(layer=layer, input_scale=input_scale, weight_scale=weight_scale,
                   bias_and_accumulator_scale=bias_scale, zero_point=0,
                   weight_max_error=float(np.abs(w - qw.astype(np.float64)*weight_scale).max()),
                   bias_max_error=float(np.abs(b - qb_wide*bias_scale).max()))
        if layer != "output":
            threshold = calibration[layer]["percentiles"][str(percentile)]
            output_scale = threshold / 127 if threshold > 0 else 1 / 127
            ratio = bias_scale / output_scale
            mult, shift = ratio_multiplier(ratio)
            represented = mult / (1 << shift)
            params.update({f"{layer}_output_scale": np.array(output_scale, np.float64),
                           f"{layer}_multiplier": np.array(mult, np.int32),
                           f"{layer}_shift": np.array(shift, np.int32)})
            row.update(output_scale=output_scale, calibration_threshold=threshold,
                       multiplier=mult, shift=shift, ratio=ratio, represented_ratio=represented,
                       absolute_ratio_error=abs(represented-ratio),
                       relative_ratio_error=abs(represented-ratio)/ratio)
            input_scale = output_scale
        else:
            row.update(output_scale=bias_scale, multiplier=None, shift=None,
                       common_logit_scale=True)
        rows.append(row)
    return params, rows, model_bounds(params)


def classify_metrics(labels, predictions):
    cm = np.bincount(labels*10 + predictions, minlength=100).reshape(10, 10)
    correct = int((labels == predictions).sum())
    assert int(cm.sum()) == len(labels) and int(cm.trace()) == correct
    return dict(count=len(labels), correct=correct, accuracy_percent=100*correct/len(labels)), cm


def plots(out, raw, labels, integer_predictions, float_predictions, cm):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt
    fig, ax = plt.subplots(figsize=(8, 7), layout="constrained")
    plot = ax.imshow(cm, cmap="Blues")
    for y in range(10):
        for x in range(10):
            ax.text(x, y, str(cm[y, x]), ha="center", va="center", fontsize=8,
                    color="white" if cm[y, x] > cm.max()/2 else "black")
    ax.set(xticks=range(10), yticks=range(10), xlabel="Predicted label", ylabel="True label",
           title="LeNet-5 B integer — 10,000 MNIST test images")
    fig.colorbar(plot, ax=ax, label="Count")
    fig.savefig(out / "confusion_matrix_integer.png", dpi=160)
    plt.close(fig)
    indices = np.flatnonzero(integer_predictions != float_predictions)[:12]
    fig, axes = plt.subplots(3, 4, figsize=(9, 7), layout="constrained")
    for ax in axes.flat:
        ax.axis("off")
    for ax, index in zip(axes.flat, indices):
        ax.imshow(np.pad(raw[index], 2), cmap="gray", vmin=0, vmax=255)
        ax.set_title(f"index {index} / true {labels[index]}\nfloat {float_predictions[index]} / int {integer_predictions[index]}", fontsize=10)
    fig.suptitle("Float/integer disagreement — first 12 by test index")
    fig.savefig(out / "float_integer_differences.png", dpi=160)
    plt.close(fig)
    np.savez_compressed(out / "difference_examples.npz", indices=indices, raw_images=raw[indices],
                         labels=labels[indices], float_predictions=float_predictions[indices],
                         integer_predictions=integer_predictions[indices])


def references(out, raw, labels, float_predictions, integer_predictions, params):
    indices = [int(np.flatnonzero(labels == label)[0]) for label in range(10)]
    indices += np.flatnonzero(float_predictions != integer_predictions)[:5].tolist()
    indices = list(dict.fromkeys(indices))
    inputs = np.concatenate([raw[indices], np.zeros((1,28,28), np.uint8), np.full((1,28,28),255,np.uint8)])
    sources = [dict(source="MNIST official test", index=i, label=int(labels[i])) for i in indices]
    sources += [dict(source="synthetic all zero", index=None, label=None),
                dict(source="synthetic all 255", index=None, label=None)]
    _, _, _, trace = inference(inputs, params, intermediates=True)
    np.savez_compressed(out / "reference.npz", raw_input=inputs, **trace)
    write_json(out / "reference_manifest.json", dict(samples=sources,
        rule="First test index per label; first 5 disagreements; then two unlabeled synthetic inputs",
        tensors={key: dict(dtype=str(value.dtype), shape=list(value.shape)) for key,value in trace.items()},
        raw_input=dict(dtype="uint8",shape=list(inputs.shape)),
        file_sha256=sha(out / "reference.npz"), not_full_test_accuracy=True))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--float-run", type=Path, default=DEFAULT_FLOAT)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--batch-size", type=int, default=32)
    args = parser.parse_args()
    if args.batch_size < 1:
        parser.error("batch-size must be positive")
    start_time = time.perf_counter()
    setup_runtime(42, 4, "cpu")
    out = fresh_directory(args.out or ROOT / "outputs/lenet5" / ("int8_" + timestamp()))
    log = (out / "run.log").open("w", encoding="utf-8", buffering=1)

    def announce(message):
        print(message, flush=True)
        log.write(message + "\n")

    before, float_before = protected_hashes(), float_run_hashes(args.float_run)
    write_json(out / "protected_before.json", dict(mlp=before, float_run=float_before))
    model, train_indices, validation_indices, checks = verify_float(args.float_run)
    write_json(out / "input_verification.json", checks)
    write_json(out / "arithmetic_checks.json", self_check())
    announce("Stage 2 input/hash checks and integer arithmetic checks PASS")
    calibration_indices = train_indices[:4096]
    assert not np.intersect1d(calibration_indices, validation_indices).size
    plan = dict(calibration_count=4096, calibration_selection="First 4096 stored train indices",
        calibration_activations="Float ReLU outputs before pooling; not sequential integer calibration",
        percentiles=list(PERCENTILES), percentile_method="linear",
        selection="max validation correct, then float/integer agreement, then largest percentile",
        weights="symmetric per tensor INT8 -127..127; zero point 0",
        activation="per tensor INT8 0..127; zero point 0", bias="INT32",
        integer_batch_size=args.batch_size, no_test_for_selection=True,
        source_sha256=source_hashes(), dataset_sha256=dataset_hashes(),
        split_sha256=sha(args.float_run / "split_indices.npz"), environment=environment(torch.device("cpu")))
    write_json(out / "plan.json", plan)
    snapshot = out / "source"
    snapshot.mkdir()
    for path in (ROOT / "lenet5").glob("*.py"):
        shutil.copy2(path, snapshot / path.name)
    raw_train = MNIST(str(DATA_DIR), train=True, download=False)
    images_train, labels_train = raw_train.data.numpy(), raw_train.targets.numpy()
    np.savez_compressed(out / "calibration_indices.npz", indices=calibration_indices,
                        labels=labels_train[calibration_indices])
    calibration = calibrate(model, images_train[calibration_indices])
    write_json(out / "calibration_statistics.json", calibration)
    val_images, val_labels = images_train[validation_indices], labels_train[validation_indices]
    val_loader = DataLoader(TensorDataset(preprocess(torch.from_numpy(val_images)), torch.from_numpy(val_labels)),
                            batch_size=256, shuffle=False)
    val_float, val_arrays = collect(model, val_loader, torch.device("cpu"))
    assert val_float["correct"] == 5917
    candidates, validation_results = [], []
    for percentile in PERCENTILES:
        params, rows, bounds = build_candidate(model, calibration, percentile)
        logits, predictions, stats = run_dataset(val_images, params, args.batch_size,
            lambda done,total: announce(f"Validation p={percentile}: {done}/{total}"))
        metrics, _ = classify_metrics(val_labels, predictions)
        agreement = int((predictions == val_arrays["predictions"]).sum())
        entry = dict(percentile=percentile, **metrics, float_integer_agreement=agreement,
                     agreement_percent=100*agreement/len(val_labels), saturation=stats)
        validation_results.append(entry)
        candidates.append((entry, params, rows, bounds))
        name = "candidate_" + str(percentile).replace(".", "p")
        np.savez_compressed(out / (name + ".npz"), **params)
        write_json(out / (name + ".json"), dict(validation=entry, scales=rows, bounds=bounds))
        announce(f"Candidate {percentile}: {metrics['correct']}/6000; agreement {agreement}/6000")
    chosen, params, rows, bounds = max(candidates, key=lambda item: (
        item[0]["correct"], item[0]["float_integer_agreement"], item[0]["percentile"]))
    write_json(out / "validation_results.json", dict(float=val_float, candidates=validation_results))
    np.savez_compressed(out / "validation_predictions.npz", indices=validation_indices, labels=val_labels,
        float_predictions=val_arrays["predictions"], integer_logits=run_dataset(val_images, params, args.batch_size)[0])
    selection = dict(chosen=chosen, scales=rows, bounds=bounds,
                     rule=plan["selection"], frozen_before_test=True)
    write_json(out / "selection.json", selection)
    selection_hash = sha(out / "selection.json")
    write_json(out / "bounds.json", bounds)
    with (out / "scales.csv").open("w", encoding="utf-8", newline="") as f:
        fields = ["layer", "input_scale", "weight_scale", "bias_and_accumulator_scale",
                  "output_scale", "multiplier", "shift", "zero_point"]
        writer = csv.DictWriter(f, fields, extrasaction="ignore")
        writer.writeheader()
        writer.writerows(rows)
    # Whole-network smoke uses train data and unlabeled synthetic inputs, not test selection.
    smoke = np.concatenate([images_train[calibration_indices[:1]], np.zeros((1,28,28),np.uint8),
                            np.full((1,28,28),255,np.uint8)])
    smoke_logits, smoke_predictions, _, smoke_trace = inference(smoke, params, intermediates=True)
    write_json(out / "network_smoke.json", dict(passed=True, classes=smoke_predictions.tolist(),
        synthetic_labels=None, tensor_shapes={k:list(v.shape) for k,v in smoke_trace.items()}))
    announce(f"Selected percentile {chosen['percentile']} using validation only; now evaluating test")
    # First access to test predictions/images occurs after model and selection are frozen.
    raw_test = MNIST(str(DATA_DIR), train=False, download=False)
    test_images, test_labels = raw_test.data.numpy(), raw_test.targets.numpy()
    with np.load(args.float_run / "test_eval/predictions.npz", allow_pickle=False) as file:
        float_predictions = file["predictions"].copy()
        assert np.array_equal(file["labels"], test_labels)
        assert np.array_equal(file["indices"], np.arange(10000))
    assert len(test_images) == 10000 and int((float_predictions==test_labels).sum()) == 9899
    logits, predictions, stats = run_dataset(test_images, params, args.batch_size,
        lambda done,total: announce(f"Full test: {done}/{total}"))
    metrics, cm = classify_metrics(test_labels, predictions)
    agreement = int((predictions == float_predictions).sum())
    np.savez_compressed(out / "test_predictions.npz", indices=np.arange(10000), labels=test_labels,
        integer_predictions=predictions, integer_logits=logits,
        float_predictions=float_predictions, confusion_matrix=cm)
    np.savetxt(out / "confusion_matrix_integer.csv", cm, fmt="%d", delimiter=",")
    write_json(out / "saturation.json", stats)
    # Save final model only after its in-memory full test, then reload and full-test again.
    np.savez_compressed(out / "lenet5_int8.npz", **params)
    metadata = dict(schema="lenet5_integer_v1", model_id=MODEL_ID, preprocessing=PREPROCESSING,
        checkpoint_sha256=checks["checkpoint_sha256"], float_run=str(args.float_run.resolve()),
        source_sha256=source_hashes(), dataset_sha256=dataset_hashes(),
        calibration_sha256=sha(out / "calibration_indices.npz"), split_sha256=plan["split_sha256"],
        selection_sha256=selection_hash, percentile=chosen["percentile"], scales=rows, bounds=bounds,
        tensors={k:dict(shape=list(v.shape), dtype=str(v.dtype), bytes=v.nbytes) for k,v in params.items()},
        layouts=dict(input="NCHW", convolution="OIHW, cross-correlation, stride1, no convolution pad",
                     linear="out,in", flatten="C then H then W row-major"),
        rounding=dict(parameters="nearest; ties away from zero",
                      requant="nonnegative nearest; half rounds upward; shift0 has zero rounding offset"),
        activation="ReLU -> requant -> saturation 0..127 -> max pool where applicable",
        pooling="2x2 stride2 maximum; preserves scale and zero point",
        accumulator="checked INT64 Python reference; static bounds prove INT32 including partial sums",
        requant="INT64 multiply before rounding offset and right shift",
        output="INT32 logits share output accumulator scale; first-index argmax, no softmax",
        model_npz_sha256=sha(out / "lenet5_int8.npz"),
        total_weight_bias_bytes=sum(v.nbytes for k,v in params.items() if k.endswith(("weight","bias"))),
        no_c_rtl_mem=True)
    write_json(out / "model_metadata.json", metadata)
    loaded = load_model(out / "lenet5_int8.npz")
    arrays_match = all(np.array_equal(params[k],loaded[k]) for k in params)
    reloaded_logits, reloaded_predictions, reloaded_stats = run_dataset(test_images, loaded, args.batch_size,
        lambda done,total: announce(f"Full test reload: {done}/{total}"))
    reload_report = dict(full_test_count=10000, tensors_equal=arrays_match,
        logits_mismatches=int(np.count_nonzero(logits!=reloaded_logits)),
        prediction_mismatches=int(np.count_nonzero(predictions!=reloaded_predictions)),
        saturation_identical=stats==reloaded_stats)
    assert arrays_match and reload_report["logits_mismatches"]==0 and reload_report["prediction_mismatches"]==0
    assert reload_report["saturation_identical"] and sha(out / "selection.json")==selection_hash
    write_json(out / "reload_verification.json", reload_report)
    plots(out, test_images, test_labels, predictions, float_predictions, cm)
    references(out, test_images, test_labels, float_predictions, predictions, loaded)
    after, float_after = protected_hashes(), float_run_hashes(args.float_run)
    assert before==after and float_before==float_after
    write_json(out / "preservation.json", dict(mlp_unchanged=before==after, float_unchanged=float_before==float_after,
        mlp_file_count=len(before), float_file_count=len(float_before), before=before, after=after,
        float_before=float_before, float_after=float_after))
    summary = dict(status="completed", **metrics, float_correct=9899, float_accuracy_percent=98.99,
        accuracy_drop_percentage_points=(9899-metrics["correct"])*100/10000,
        float_integer_agreement=agreement, agreement_percent=agreement*100/10000,
        chosen_percentile=chosen["percentile"], validation_correct=chosen["correct"],
        full_test_reload=reload_report, checkpoint_sha256=checks["checkpoint_sha256"],
        frozen_selection_sha256=selection_hash, total_seconds=time.perf_counter()-start_time,
        scope="Stage3 Python integer MNIST; C/RTL/mem/FPGA/camera not implemented")
    write_json(out / "metrics.json", summary)
    announce(f"DONE: integer {metrics['correct']}/10000={metrics['accuracy_percent']:.2f}%; "
             f"float 98.99%; drop {summary['accuracy_drop_percentage_points']:.2f} pp; agreement {agreement}/10000")
    announce(f"Reload full test exact; preserved MLP and float outputs. Saved: {out}")
    log.close()


if __name__ == "__main__":
    main()
