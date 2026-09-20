import argparse
from collections.abc import Mapping
from pathlib import Path

import torch
from torch import nn
from torch.utils.data import DataLoader
from torchvision import datasets, transforms


class MLP(nn.Module):
    def __init__(self):
        super().__init__()
        self.flatten = nn.Flatten()
        self.fc1 = nn.Linear(784, 16, bias=True)
        self.relu = nn.ReLU()
        self.fc2 = nn.Linear(16, 10, bias=True)

    def forward(self, image):
        x = self.flatten(image)
        z1 = self.fc1(x)
        h = self.relu(z1)
        logits = self.fc2(h)
        return logits


EXPECTED_SHAPES = {
    "fc1.weight": (16, 784),
    "fc1.bias": (16,),
    "fc2.weight": (10, 16),
    "fc2.bias": (10,),
}


def extract_state_dict(checkpoint):
    """Find parameter tensors without assuming one checkpoint layout."""
    if not isinstance(checkpoint, Mapping):
        raise ValueError(
            "Checkpoint is not a dictionary. "
            "Please inspect how train_mlp.py saves the model."
        )

    # Case 1: torch.save(model.state_dict(), path)
    if all(key in checkpoint for key in EXPECTED_SHAPES):
        return checkpoint

    # Case 2: parameters are inside a checkpoint dictionary
    for name in ("model_state_dict", "state_dict", "model"):
        candidate = checkpoint.get(name)
        if isinstance(candidate, Mapping):
            if all(key in candidate for key in EXPECTED_SHAPES):
                print(f"Parameter dictionary: {name}")
                return candidate

    raise ValueError(
        "Cannot find the four expected parameter tensors. "
        f"Checkpoint keys: {list(checkpoint.keys())}"
    )


def check_parameters(state_dict):
    total = 0

    print("\nParameter inspection:")
    for name, expected_shape in EXPECTED_SHAPES.items():
        tensor = state_dict[name]

        if not isinstance(tensor, torch.Tensor):
            raise TypeError(f"{name} is not a tensor.")

        if tuple(tensor.shape) != expected_shape:
            raise ValueError(
                f"{name}: expected {expected_shape}, "
                f"received {tuple(tensor.shape)}"
            )

        if not torch.isfinite(tensor).all().item():
            raise ValueError(f"{name} contains NaN or infinity.")

        total += tensor.numel()

        print(
            f"{name}: shape={tuple(tensor.shape)}, "
            f"dtype={tensor.dtype}, "
            f"min={tensor.min().item():.6f}, "
            f"max={tensor.max().item():.6f}"
        )

    print(f"Total parameters: {total}")


@torch.inference_mode()
def evaluate(model, loader):
    model.eval()

    loss_function = nn.CrossEntropyLoss(reduction="sum")
    total_loss = 0.0
    total_correct = 0
    total_images = 0
    examples = []

    for images, labels in loader:
        logits = model(images)
        predictions = logits.argmax(dim=1)

        total_loss += loss_function(logits, labels).item()
        total_correct += (predictions == labels).sum().item()
        total_images += labels.numel()

        remaining = 10 - len(examples)
        if remaining > 0:
            examples.extend(
                zip(
                    labels[:remaining].tolist(),
                    predictions[:remaining].tolist(),
                )
            )

    return (
        total_loss / total_images,
        100.0 * total_correct / total_images,
        total_correct,
        total_images,
        examples,
    )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--checkpoint",
        type=Path,
        default=Path("outputs/run1/mlp_best.pt"),
    )
    parser.add_argument("--data-dir", type=Path, default=Path("data"))
    parser.add_argument("--batch-size", type=int, default=256)
    args = parser.parse_args()

    if not args.checkpoint.is_file():
        raise FileNotFoundError(
            f"Checkpoint not found: {args.checkpoint.resolve()}"
        )

    print(f"Loading: {args.checkpoint.resolve()}")

    checkpoint = torch.load(
        args.checkpoint,
        map_location="cpu",
        weights_only=True,
    )

    state_dict = extract_state_dict(checkpoint)
    check_parameters(state_dict)

    model = MLP()
    model.load_state_dict(state_dict, strict=True)
    model.eval()

    # Assumes training used pixel / 255 without extra normalization.
    test_dataset = datasets.MNIST(
        root=str(args.data_dir),
        train=False,
        download=True,
        transform=transforms.ToTensor(),
    )

    test_loader = DataLoader(
        test_dataset,
        batch_size=args.batch_size,
        shuffle=False,
        num_workers=0,
    )

    loss, accuracy, correct, total, examples = evaluate(model, test_loader)

    print(f"\nTest images: {total}")
    print(f"Correct predictions: {correct}")
    print(f"Test loss: {loss:.4f}")
    print(f"Test accuracy: {accuracy:.2f}%")
    print(f"Difference from 95.13%: {accuracy - 95.13:+.2f} percentage points")

    print("\nFirst 10 test samples:")
    for index, (label, prediction) in enumerate(examples):
        status = "OK" if label == prediction else "WRONG"
        print(
            f"Sample {index}: label={label}, "
            f"prediction={prediction} [{status}]"
        )

    print("\nCheckpoint loading and evaluation completed.")


if __name__ == "__main__":
    main()