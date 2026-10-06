"""Experiment metadata, provenance and runtime settings."""
import hashlib
import json
import os
import platform
import random
from datetime import datetime, timedelta, timezone
from pathlib import Path

import numpy as np
import torch
import torchvision
import matplotlib

from lenet5.data import ROOT


def timestamp():
    return datetime.now(timezone(timedelta(hours=7))).strftime("%Y%m%d_%H%M%S_%f")


def write_json(path, value):
    Path(path).write_text(json.dumps(value, indent=2, ensure_ascii=False,
                                    allow_nan=False), encoding="utf-8")


def fresh_directory(path):
    path = Path(path).resolve()
    allowed = (ROOT / "outputs" / "lenet5").resolve()
    if allowed not in path.parents:
        raise ValueError("Output must be a subdirectory of outputs/lenet5")
    if path.exists() and any(path.iterdir()):
        raise ValueError(f"Refusing nonempty output directory: {path}")
    path.mkdir(parents=True, exist_ok=True)
    return path


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def protected_hashes():
    files = list(ROOT.glob("*.py")) + [ROOT / "AGENTS.md", ROOT / "README.md"]
    files += [p for p in (ROOT / "rtl").rglob("*") if p.is_file()]
    for name in ("run1", "int8_run1", "c_run1"):
        files += [p for p in (ROOT / "outputs" / name).rglob("*") if p.is_file()]
    return {str(p.relative_to(ROOT)).replace("\\", "/"): sha(p)
            for p in sorted(files)}


def dataset_hashes():
    return {name: sha(ROOT / "data" / "MNIST" / "raw" / name) for name in (
        "train-images-idx3-ubyte", "train-labels-idx1-ubyte",
        "t10k-images-idx3-ubyte", "t10k-labels-idx1-ubyte")}


def source_hashes():
    return {p.name: sha(p) for p in sorted((ROOT / "lenet5").glob("*.py"))}


def setup_runtime(seed, threads, device="auto"):
    torch.set_num_threads(threads)
    torch.set_num_interop_threads(1)
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)
    torch.use_deterministic_algorithms(True)
    torch.backends.cudnn.benchmark = False
    torch.backends.cudnn.deterministic = True
    if device == "auto":
        device = "cuda" if torch.cuda.is_available() else "cpu"
    if device == "cuda" and not torch.cuda.is_available():
        raise ValueError("CUDA unavailable")
    return torch.device(device)


def reseed(seed):
    random.seed(seed)
    np.random.seed(seed)
    torch.manual_seed(seed)
    if torch.cuda.is_available():
        torch.cuda.manual_seed_all(seed)


def environment(device):
    return dict(python=platform.python_version(), platform=platform.platform(),
                torch=str(torch.__version__), torchvision=str(torchvision.__version__),
                numpy=np.__version__, matplotlib=matplotlib.__version__,
                device=str(device), cuda_available=torch.cuda.is_available(),
                device_name=torch.cuda.get_device_name(device) if device.type == "cuda" else platform.processor(),
                cpu_count=os.cpu_count(), threads=torch.get_num_threads(),
                interop_threads=torch.get_num_interop_threads(),
                deterministic_algorithms=torch.are_deterministic_algorithms_enabled(),
                cudnn_benchmark=torch.backends.cudnn.benchmark,
                cudnn_deterministic=torch.backends.cudnn.deterministic,
                reproducibility_limit="No bitwise guarantee across hardware or library versions")
