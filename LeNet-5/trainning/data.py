"""Local MNIST only; pad without resizing and preserve official test order."""
from pathlib import Path

import torch
from torch.nn import functional as F
from torch.utils.data import TensorDataset, random_split
from torchvision.datasets import MNIST

ROOT = Path(__file__).resolve().parents[1]
DATA_DIR = ROOT / "data"
PREPROCESSING = {
    "raw_dtype": "uint8", "raw_shape": [1, 28, 28],
    "pad_each_edge": 2, "pad_value": 0, "resize": False,
    "float_dtype": "float32", "normalization": "pixel / 255",
    "input_shape": [1, 32, 32], "layout": "NCHW",
    "polarity": "bright strokes on dark background",
    "augmentation": "none",
}


def preprocess(raw):
    if raw.dtype != torch.uint8 or tuple(raw.shape[-2:]) != (28, 28):
        raise ValueError("Expected raw uint8 MNIST [...,28,28]")
    if raw.ndim == 2:
        raw = raw.unsqueeze(0)
    elif raw.ndim == 3:
        raw = raw.unsqueeze(1)
    else:
        raise ValueError("Expected one image or a batch of raw images")
    return F.pad(raw.to(torch.float32).div(255), (2, 2, 2, 2), value=0)


def local_dataset(train, data_dir=DATA_DIR):
    raw = MNIST(str(data_dir), train=train, download=False)
    # Materialize once to avoid PIL conversions on every epoch; same pixel/255.
    return TensorDataset(preprocess(raw.data), raw.targets.clone()), raw


def split_training(dataset, seed):
    if len(dataset) != 60000:
        raise ValueError("Expected 60000 official MNIST training images")
    return random_split(dataset, [54000, 6000],
                        generator=torch.Generator().manual_seed(seed))
