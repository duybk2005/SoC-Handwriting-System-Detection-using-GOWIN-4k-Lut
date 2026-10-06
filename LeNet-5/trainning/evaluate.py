"""Evaluate a saved float checkpoint on all 10000 official MNIST test images."""
import argparse
from pathlib import Path

import numpy as np
import torch
from torch.utils.data import DataLoader
from torch.nn import functional as F

from lenet5.common import (environment, fresh_directory, setup_runtime, sha,
                           source_hashes, timestamp, write_json, dataset_hashes)
from lenet5.data import DATA_DIR, PREPROCESSING, ROOT, local_dataset
from lenet5.model import LeNet5B, MODEL_ID, PARAMETERS


@torch.inference_mode()
def collect(model, loader, device):
    model.eval()
    labels, outputs = [], []
    total_loss = 0.0
    for images, target in loader:
        logits = model(images.to(device))
        if not torch.isfinite(logits).all():
            raise ValueError("Non-finite logits")
        total_loss += F.cross_entropy(logits, target.to(device), reduction="sum").item()
        labels.append(target.numpy())
        outputs.append(logits.cpu().numpy())
    labels, logits = np.concatenate(labels), np.concatenate(outputs)
    predictions = logits.argmax(axis=1)
    cm = np.bincount(labels * 10 + predictions, minlength=100).reshape(10, 10)
    correct = int((labels == predictions).sum())
    assert int(cm.sum()) == len(labels) and int(cm.trace()) == correct
    metrics = dict(count=len(labels), correct=correct, loss=total_loss / len(labels),
                   accuracy=correct / len(labels), accuracy_percent=correct * 100 / len(labels),
                   confusion_rows="true label", confusion_columns="predicted label")
    return metrics, dict(indices=np.arange(len(labels)), labels=labels,
                         predictions=predictions, logits=logits, confusion_matrix=cm)


def evaluate_checkpoint(checkpoint, out, device, data_dir=DATA_DIR, batch_size=256):
    out = fresh_directory(out)
    ckpt = torch.load(checkpoint, map_location="cpu", weights_only=True)
    if ckpt["config"]["model_id"] != MODEL_ID or ckpt["config"]["preprocessing"] != PREPROCESSING:
        raise ValueError("Checkpoint architecture/preprocessing mismatch")
    model = LeNet5B().to(device)
    model.load_state_dict(ckpt["model_state_dict"], strict=True)
    assert sum(p.numel() for p in model.parameters()) == PARAMETERS
    dataset, raw = local_dataset(False, data_dir)
    assert len(dataset) == 10000
    loader = DataLoader(dataset, batch_size=batch_size, shuffle=False, num_workers=0,
                        drop_last=False, generator=torch.Generator().manual_seed(ckpt["config"]["seed"]))
    metrics, arrays = collect(model, loader, device)
    assert arrays["logits"].shape == (10000, 10)
    metrics.update(checkpoint=str(Path(checkpoint).resolve()), checkpoint_sha256=sha(checkpoint),
                   checkpoint_epoch=ckpt["epoch"], batch_size=batch_size,
                   model_id=MODEL_ID, preprocessing=PREPROCESSING,
                   environment=environment(device), source_sha256=source_hashes(),
                   dataset_sha256=dataset_hashes(),
                   parameter_count=PARAMETERS, parameter_float32_bytes=PARAMETERS * 4,
                   checkpoint_file_bytes=Path(checkpoint).stat().st_size,
                   scope="MNIST float only; no integer, FPGA or camera evaluation")
    write_json(out / "metrics.json", metrics)
    np.savez_compressed(out / "predictions.npz", **arrays)
    np.savetxt(out / "confusion_matrix.csv", arrays["confusion_matrix"], fmt="%d", delimiter=",")
    from lenet5.plots import evaluation_plots
    evaluation_plots(out, arrays, raw.data.numpy())
    return metrics


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--checkpoint", required=True, type=Path)
    parser.add_argument("--out", type=Path)
    parser.add_argument("--compare-to", type=Path, help="Prior evaluation directory")
    parser.add_argument("--device", choices=["auto", "cpu", "cuda"])
    parser.add_argument("--threads", type=int)
    parser.add_argument("--batch-size", type=int)
    args = parser.parse_args()
    ckpt = torch.load(args.checkpoint, map_location="cpu", weights_only=True)
    config = ckpt["config"]
    threads = args.threads if args.threads is not None else config["environment"]["threads"]
    batch_size = args.batch_size if args.batch_size is not None else config["evaluation_batch_size"]
    if threads < 1 or batch_size < 1:
        parser.error("threads and batch-size must be positive")
    device = setup_runtime(config["seed"], threads,
                           args.device or config["environment"]["device"])
    out = args.out or ROOT / "outputs" / "lenet5" / ("eval_" + timestamp())
    metrics = evaluate_checkpoint(args.checkpoint, out, device, batch_size=batch_size)
    if args.compare_to:
        previous = np.load(args.compare_to / "predictions.npz")
        actual = np.load(out / "predictions.npz")
        same = {key: bool(np.array_equal(previous[key], actual[key])) for key in actual.files}
        import json
        old = json.loads((args.compare_to / "metrics.json").read_text(encoding="utf-8"))
        report = dict(arrays_bit_exact=same, loss_identical=old["loss"] == metrics["loss"],
                      correct_identical=old["correct"] == metrics["correct"],
                      checkpoint_identical=old["checkpoint_sha256"] == metrics["checkpoint_sha256"],
                      reference=str(args.compare_to.resolve()))
        write_json(out / "comparison.json", report)
        if not all(same.values()) or not report["loss_identical"] or not report["checkpoint_identical"]:
            raise RuntimeError("Independent evaluation mismatch; inspect comparison.json")
    print(f"Full test: {metrics['correct']}/10000 = {metrics['accuracy_percent']:.2f}%; loss={metrics['loss']:.8f}")
    print(f"Saved: {Path(out).resolve()}")


if __name__ == "__main__":
    main()
