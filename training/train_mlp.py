import argparse
import copy
import csv
import json
from pathlib import Path

import torch
from torch import nn
from torch.utils.data import DataLoader, random_split
from torchvision import datasets, transforms


# Kien truc da chot
INPUT_SIZE = 784
HIDDEN_SIZE = 16
OUTPUT_SIZE = 10
SEED = 42

ROOT = Path(__file__).resolve().parent
DATA_DIR = ROOT / "data"


class MLP(nn.Module):
    def __init__(self):
        super().__init__()

        self.flatten = nn.Flatten()
        self.fc1 = nn.Linear(INPUT_SIZE, HIDDEN_SIZE, bias=True)
        self.relu = nn.ReLU()
        self.fc2 = nn.Linear(HIDDEN_SIZE, OUTPUT_SIZE, bias=True)

    def forward(self, images):
        x = self.flatten(images)
        z1 = self.fc1(x)
        h = self.relu(z1)
        logits = self.fc2(h)
        return logits


def train_one_epoch(model, loader, criterion, optimizer):
    model.train()

    total_loss = 0.0
    total_correct = 0
    total_samples = 0

    for images, labels in loader:
        optimizer.zero_grad()

        logits = model(images)
        loss = criterion(logits, labels)

        loss.backward()
        optimizer.step()

        batch_size = labels.size(0)
        total_loss += loss.item() * batch_size
        total_correct += (
            logits.argmax(dim=1) == labels
        ).sum().item()
        total_samples += batch_size

    return (
        total_loss / total_samples,
        total_correct / total_samples,
    )


@torch.no_grad()
def evaluate(model, loader, criterion):
    model.eval()

    total_loss = 0.0
    total_correct = 0
    total_samples = 0

    for images, labels in loader:
        logits = model(images)
        loss = criterion(logits, labels)

        batch_size = labels.size(0)
        total_loss += loss.item() * batch_size
        total_correct += (
            logits.argmax(dim=1) == labels
        ).sum().item()
        total_samples += batch_size

    return (
        total_loss / total_samples,
        total_correct / total_samples,
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--epochs", type=int, default=20)
    parser.add_argument("--batch-size", type=int, default=64)
    parser.add_argument("--lr", type=float, default=0.001)
    parser.add_argument("--out", type=str, default="outputs/run1")
    args = parser.parse_args()

    if args.epochs < 1 or args.batch_size < 1 or args.lr <= 0:
        parser.error("epochs, batch-size and lr must be positive")

    torch.manual_seed(SEED)

    out_dir = ROOT / args.out
    out_dir.mkdir(parents=True, exist_ok=True)

    # MNIST: PIL image -> tensor [1, 28, 28], gia tri 0..1.
    # ToTensor da chia pixel cho 255.
    transform = transforms.ToTensor()

    full_train = datasets.MNIST(
        root=str(DATA_DIR),
        train=True,
        download=True,
        transform=transform,
    )

    test_set = datasets.MNIST(
        root=str(DATA_DIR),
        train=False,
        download=True,
        transform=transform,
    )

    # Tach 60.000 anh thanh train va validation.
    train_set, val_set = random_split(
        full_train,
        [54000, 6000],
        generator=torch.Generator().manual_seed(SEED),
    )

    train_loader = DataLoader(
        train_set,
        batch_size=args.batch_size,
        shuffle=True,
        num_workers=0,
        generator=torch.Generator().manual_seed(SEED),
    )

    val_loader = DataLoader(
        val_set,
        batch_size=256,
        shuffle=False,
        num_workers=0,
    )

    test_loader = DataLoader(
        test_set,
        batch_size=256,
        shuffle=False,
        num_workers=0,
    )

    model = MLP()
    criterion = nn.CrossEntropyLoss()
    optimizer = torch.optim.Adam(
        model.parameters(),
        lr=args.lr,
    )

    config = {
        "input_size": INPUT_SIZE,
        "hidden_size": HIDDEN_SIZE,
        "output_size": OUTPUT_SIZE,
        "seed": SEED,
        "epochs": args.epochs,
        "batch_size": args.batch_size,
        "learning_rate": args.lr,
        "optimizer": "Adam",
        "input_preprocessing": "pixel / 255",
        "flatten_order": "row_major",
        "torch_version": str(torch.__version__),
    }

    print(model)
    print("Device: CPU")
    print("Parameters:", sum(p.numel() for p in model.parameters()))
    print("Train / validation / test: 54000 / 6000 / 10000")

    best_val_loss = float("inf")
    best_state = None
    best_epoch = 0
    history = []

    for epoch in range(1, args.epochs + 1):
        train_loss, train_acc = train_one_epoch(
            model, train_loader, criterion, optimizer
        )
        val_loss, val_acc = evaluate(
            model, val_loader, criterion
        )

        history.append({
            "epoch": epoch,
            "train_loss": train_loss,
            "train_accuracy": train_acc,
            "val_loss": val_loss,
            "val_accuracy": val_acc,
        })

        print(
            f"Epoch {epoch:02d}/{args.epochs} | "
            f"train loss={train_loss:.4f}, "
            f"acc={100 * train_acc:.2f}% | "
            f"val loss={val_loss:.4f}, "
            f"acc={100 * val_acc:.2f}%"
        )

        # Chon checkpoint theo validation loss.
        if val_loss < best_val_loss:
            best_val_loss = val_loss
            best_epoch = epoch
            best_state = copy.deepcopy(model.state_dict())

            torch.save({
                "model_state_dict": best_state,
                "config": config,
                "best_epoch": best_epoch,
                "val_loss": val_loss,
                "val_accuracy": val_acc,
            }, out_dir / "mlp_best.pt")

    # Danh gia test sau khi da chon checkpoint.
    model.load_state_dict(best_state)
    test_loss, test_acc = evaluate(
        model, test_loader, criterion
    )

    print(f"\nBest epoch: {best_epoch}")
    print(f"Test loss: {test_loss:.4f}")
    print(f"Test accuracy: {100 * test_acc:.2f}%")

    print("\nStored parameter shapes:")
    for name, value in model.state_dict().items():
        print(f"  {name}: {tuple(value.shape)}")

    model.eval()
    with torch.no_grad():
        images, labels = next(iter(test_loader))
        logits = model(images[:10])
        predictions = logits.argmax(dim=1)

    print("\nFirst 10 test samples:")
    for index in range(10):
        expected = labels[index].item()
        predicted = predictions[index].item()
        status = "OK" if expected == predicted else "WRONG"
        print(
            f"Sample {index}: label={expected}, "
            f"prediction={predicted} [{status}]"
        )

    with (out_dir / "history.csv").open(
        "w", newline="", encoding="utf-8"
    ) as file:
        writer = csv.DictWriter(
            file, fieldnames=list(history[0].keys())
        )
        writer.writeheader()
        writer.writerows(history)

    with (out_dir / "metrics.json").open(
        "w", encoding="utf-8"
    ) as file:
        json.dump({
            "config": config,
            "best_epoch": best_epoch,
            "test_loss": test_loss,
            "test_accuracy": test_acc,
        }, file, indent=2)

    print(f"\nResults saved to: {out_dir}")


if __name__ == "__main__":
    main()