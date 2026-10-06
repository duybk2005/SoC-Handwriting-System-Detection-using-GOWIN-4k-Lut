"""Rebuild report figures from stored numerical results."""
import csv
from pathlib import Path

import matplotlib
matplotlib.use("Agg")
import matplotlib.pyplot as plt
import numpy as np

from lenet5.common import write_json


def history_plots(out):
    out = Path(out)
    with (out / "history.csv").open(encoding="utf-8", newline="") as f:
        rows = list(csv.DictReader(f))
    epochs = [int(r["epoch"]) for r in rows]
    for metric, label in (("loss", "Cross-entropy loss"), ("accuracy", "Accuracy (%)")):
        fig, ax = plt.subplots(figsize=(8, 4.5), layout="constrained")
        for split in ("train", "val"):
            values = [float(r[f"{split}_{metric}"]) for r in rows]
            if metric == "accuracy":
                values = np.asarray(values) * 100
            ax.plot(epochs, values, marker=".", label=split)
        ax.set(xlabel="Epoch", ylabel=label, title="LeNet-5 variant B — MNIST float")
        ax.set_xticks(epochs[::max(1, len(epochs) // 10)])
        ax.grid(alpha=0.25)
        ax.legend()
        fig.savefig(out / f"{metric}.png", dpi=160)
        plt.close(fig)


def evaluation_plots(out, arrays, images):
    out = Path(out)
    cm = arrays["confusion_matrix"]
    fig, ax = plt.subplots(figsize=(8, 7), layout="constrained")
    plotted = ax.imshow(cm, cmap="Blues")
    for y in range(10):
        for x in range(10):
            ax.text(x, y, str(cm[y, x]), ha="center", va="center", fontsize=8,
                    color="white" if cm[y, x] > cm.max() / 2 else "black")
    ax.set(xticks=range(10), yticks=range(10), xlabel="Predicted label", ylabel="True label",
           title="LeNet-5 variant B — all 10,000 MNIST test images")
    fig.colorbar(plotted, ax=ax, label="Count")
    fig.savefig(out / "confusion_matrix.png", dpi=160)
    plt.close(fig)
    correct = arrays["labels"] == arrays["predictions"]
    selections = {}
    for name, mask in (("correct_examples", correct), ("wrong_examples", ~correct)):
        indices = np.flatnonzero(mask)[:12]
        selections[name] = indices.tolist()
        fig, axes = plt.subplots(3, 4, figsize=(9, 7), layout="constrained")
        for ax in axes.flat:
            ax.axis("off")
        for ax, index in zip(axes.flat, indices):
            ax.imshow(np.pad(images[index], 2), cmap="gray", vmin=0, vmax=255)
            ax.set_title(f"index {index}\ntrue {arrays['labels'][index]} / pred {arrays['predictions'][index]}", fontsize=10)
        fig.suptitle(f"{name.replace('_', ' ').title()} — first 12 by test index")
        fig.savefig(out / f"{name}.png", dpi=160)
        plt.close(fig)
    write_json(out / "example_selection.json", dict(rule="First up to 12 matching test indices, ascending", **selections))
    union = selections["correct_examples"] + selections["wrong_examples"]
    np.savez_compressed(out / "example_images.npz", indices=union,
                        raw_images=images[union], labels=arrays["labels"][union],
                        predictions=arrays["predictions"][union])
