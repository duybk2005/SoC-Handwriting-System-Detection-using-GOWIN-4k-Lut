"""One reproducible float run of the selected LeNet-5 variant B."""
import argparse
import csv
import math
import os
import shutil
import time
from pathlib import Path

import numpy as np
import torch
from torch import nn
from torch.utils.data import DataLoader

from lenet5.common import (dataset_hashes, environment, fresh_directory,
                           protected_hashes, reseed, setup_runtime,
                           source_hashes, timestamp, write_json)
from lenet5.data import PREPROCESSING, ROOT, local_dataset, preprocess, split_training
from lenet5.evaluate import collect, evaluate_checkpoint
from lenet5.model import EXPECTED_SHAPES, LeNet5B, MODEL_ID, PARAMETERS
from lenet5.plots import history_plots


def preflight(dataset, raw, train_set, val_set, device):
    x = preprocess(raw.data[:8])
    assert x.shape == (8, 1, 32, 32) and x.dtype == torch.float32
    assert x.min() >= 0 and x.max() <= 1
    assert torch.equal(x[:, 0, 2:-2, 2:-2], raw.data[:8].float() / 255)
    assert not x[:, :, :2].count_nonzero() and not x[:, :, -2:].count_nonzero()
    assert not x[:, :, :, :2].count_nonzero() and not x[:, :, :, -2:].count_nonzero()
    assert preprocess(raw.data[0]).shape == (1, 32, 32)
    indices = np.array(train_set.indices + val_set.indices)
    assert len(train_set) == 54000 and len(val_set) == 6000
    assert np.array_equal(np.sort(indices), np.arange(60000))
    model = LeNet5B().to(device)
    assert sum(p.numel() for p in model.parameters()) == PARAMETERS
    shapes, counts = {}, {}
    h = x.to(device)
    for name, layer in model.layers.named_children():
        h = layer(h)
        shapes[name] = list(h.shape[1:])
        counts[name] = sum(p.numel() for p in layer.parameters())
        if name in EXPECTED_SHAPES:
            assert shapes[name] == EXPECTED_SHAPES[name]
    loss = nn.CrossEntropyLoss()(model(x.to(device)), raw.targets[:8].to(device))
    assert torch.isfinite(loss)
    loss.backward()
    assert all(p.grad is not None and torch.isfinite(p.grad).all() for p in model.parameters())
    assert torch.tensor([[1., 1., 0.]]).argmax(1).item() == 0
    return dict(passed=True, shapes=shapes, layer_parameters=counts,
                parameter_count=PARAMETERS, pad_preserves_pixels=True,
                pad_zero=True, split_disjoint_and_complete=True,
                forward_backward_finite=True, argmax_first_tie=True,
                smoke_loss=float(loss.item()), smoke_batch_size=8,
                rng_reset_and_new_model_before_training=True)


def train_epoch(model, loader, criterion, optimizer, device):
    model.train()
    loss_sum, correct, count = 0.0, 0, 0
    for images, labels in loader:
        images, labels = images.to(device), labels.to(device)
        optimizer.zero_grad(set_to_none=True)
        logits = model(images)
        loss = criterion(logits, labels)
        if not torch.isfinite(loss):
            raise ValueError("Non-finite training loss")
        loss.backward()
        optimizer.step()
        loss_sum += loss.item() * len(labels)
        correct += int((logits.argmax(1) == labels).sum().item())
        count += len(labels)
    assert count == 54000
    return loss_sum / count, correct / count


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--epochs", type=int, default=20)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--lr", type=float, default=0.001)
    parser.add_argument("--seed", type=int, default=42)
    parser.add_argument("--threads", type=int, default=min(4, os.cpu_count() or 1))
    parser.add_argument("--device", choices=["auto", "cpu", "cuda"], default="auto")
    parser.add_argument("--out", type=Path)
    args = parser.parse_args()
    if min(args.epochs, args.batch_size, args.threads) < 1 or not math.isfinite(args.lr) or args.lr <= 0:
        parser.error("epochs, batch-size, threads and lr must be positive and finite")
    device = setup_runtime(args.seed, args.threads, args.device)
    out = fresh_directory(args.out or ROOT / "outputs" / "lenet5" / ("float_" + timestamp()))
    log = (out / "training.log").open("w", encoding="utf-8", buffering=1)

    def announce(message):
        print(message, flush=True)
        log.write(message + "\n")

    protected_before = protected_hashes()
    write_json(out / "protected_before.json", protected_before)
    config = dict(model_id=MODEL_ID, parameter_count=PARAMETERS, preprocessing=PREPROCESSING,
                  seed=args.seed, epochs=args.epochs, batch_size=args.batch_size,
                  learning_rate=args.lr, optimizer="Adam", adam_betas=[0.9, 0.999],
                  adam_eps=1e-8, weight_decay=0.0, loss="CrossEntropyLoss",
                  checkpoint_selection="lowest validation loss; keep earlier on tie",
                  split_sizes=[54000, 6000], test_count=10000, shuffle=True,
                  drop_last=False, num_workers=0, evaluation_batch_size=256,
                  environment=environment(device), dataset_sha256=dataset_hashes(),
                  source_sha256=source_hashes())
    write_json(out / "config.json", config)
    snapshot = out / "source"
    snapshot.mkdir()
    for p in (ROOT / "lenet5").glob("*.py"):
        shutil.copy2(p, snapshot / p.name)
    shutil.copy2(ROOT / "lenet5" / "ARCHITECTURE_PROPOSAL.md", snapshot)
    dataset, raw = local_dataset(True)
    train_set, val_set = split_training(dataset, args.seed)
    np.savez_compressed(out / "split_indices.npz", train=np.asarray(train_set.indices),
                        validation=np.asarray(val_set.indices), seed=args.seed)
    checks = preflight(dataset, raw, train_set, val_set, device)
    write_json(out / "preflight.json", checks)
    announce(f"Preflight PASS: {PARAMETERS} parameters, shapes/padding/split/backward verified")
    announce(f"Device: {device}; threads: {args.threads}; output: {out}")
    # Discard smoke model and explicitly reset every training RNG.
    reseed(args.seed)
    model = LeNet5B().to(device)
    write_json(out / "parameters.json", model.parameter_description())
    train_loader = DataLoader(train_set, batch_size=args.batch_size, shuffle=True,
                              num_workers=0, drop_last=False,
                              generator=torch.Generator().manual_seed(args.seed))
    val_loader = DataLoader(val_set, batch_size=256, shuffle=False, num_workers=0,
                            drop_last=False, generator=torch.Generator().manual_seed(args.seed))
    optimizer = torch.optim.Adam(model.parameters(), lr=args.lr)
    criterion = nn.CrossEntropyLoss()
    best_loss, best_epoch, best_acc = float("inf"), 0, 0.0
    start = time.perf_counter()
    with (out / "history.csv").open("w", encoding="utf-8", newline="") as f:
        writer = csv.DictWriter(f, fieldnames=["epoch", "train_loss", "train_accuracy",
                               "val_loss", "val_accuracy", "epoch_seconds"])
        writer.writeheader()
        for epoch in range(1, args.epochs + 1):
            epoch_start = time.perf_counter()
            train_loss, train_acc = train_epoch(model, train_loader, criterion, optimizer, device)
            val, _ = collect(model, val_loader, device)
            assert val["count"] == 6000
            state = dict(model_state_dict={k: v.detach().cpu().clone() for k, v in model.state_dict().items()},
                         config=config, epoch=epoch, val_loss=val["loss"], val_accuracy=val["accuracy"])
            if val["loss"] < best_loss:
                best_loss, best_epoch, best_acc = val["loss"], epoch, val["accuracy"]
                torch.save(state, out / "lenet5_best.pt")
            if epoch == args.epochs:
                torch.save(state, out / "lenet5_last.pt")
            elapsed = time.perf_counter() - epoch_start
            writer.writerow(dict(epoch=epoch, train_loss=train_loss, train_accuracy=train_acc,
                                 val_loss=val["loss"], val_accuracy=val["accuracy"], epoch_seconds=elapsed))
            f.flush()
            announce(f"Epoch {epoch:02d}/{args.epochs}: train loss={train_loss:.6f} acc={train_acc*100:.2f}% | "
                     f"val loss={val['loss']:.6f} acc={val['accuracy_percent']:.2f}% | {elapsed:.1f}s | best={best_epoch}")
    training_seconds = time.perf_counter() - start
    # First test access occurs only after checkpoint selection is complete.
    metrics = evaluate_checkpoint(out / "lenet5_best.pt", out / "test_eval", device)
    history_plots(out)
    protected_after = protected_hashes()
    unchanged = protected_before == protected_after
    write_json(out / "preservation.json", dict(unchanged=unchanged,
               file_count=len(protected_before), before=protected_before, after=protected_after))
    summary = dict(status="completed", best_epoch=best_epoch, best_val_loss=best_loss,
                   best_val_accuracy=best_acc, best_val_accuracy_percent=best_acc*100,
                   epochs_completed=args.epochs, training_seconds=training_seconds,
                   parameter_count=PARAMETERS, parameter_float32_bytes=PARAMETERS*4,
                   best_checkpoint_bytes=(out / "lenet5_best.pt").stat().st_size,
                   last_checkpoint_bytes=(out / "lenet5_last.pt").stat().st_size,
                   test=metrics, protected_files_unchanged=unchanged,
                   scope="Stage 2 float MNIST only")
    write_json(out / "metrics.json", summary)
    if not unchanged:
        raise RuntimeError("Protected MLP file changed")
    announce(f"Completed: best epoch {best_epoch}; test {metrics['correct']}/10000 = {metrics['accuracy_percent']:.2f}%; training {training_seconds:.1f}s")
    log.close()


if __name__ == "__main__":
    main()
