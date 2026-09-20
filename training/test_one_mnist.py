"""Run the exported C inference on one local MNIST test image."""
import argparse
import ctypes
import os
import subprocess
from pathlib import Path

import numpy as np
from PIL import Image
from torchvision.datasets import MNIST


ROOT = Path(__file__).resolve().parent


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--index", type=int, default=0,
                        help="MNIST test index, from 0 to 9999")
    parser.add_argument("--gcc", default="C:/msys64/ucrt64/bin/gcc.exe")
    parser.add_argument("--out", type=Path,
                        default=ROOT / "outputs" / "one_image_demo")
    args = parser.parse_args()

    if not 0 <= args.index < 10000:
        parser.error("--index must be between 0 and 9999")

    dataset = MNIST(str(ROOT / "data"), train=False, download=False)
    image_2d = dataset.data[args.index].numpy()
    true_label = int(dataset.targets[args.index])
    image = np.ascontiguousarray(image_2d.reshape(784), dtype=np.uint8)

    args.out.mkdir(parents=True, exist_ok=True)
    preview_path = args.out / f"mnist_test_{args.index}_label_{true_label}.png"
    Image.fromarray(image_2d, mode="L").resize(
        (280, 280), Image.Resampling.NEAREST
    ).save(preview_path)

    gcc = Path(args.gcc).resolve()
    if not gcc.is_file():
        raise FileNotFoundError(f"GCC not found: {gcc}")
    os.environ["PATH"] = str(gcc.parent) + os.pathsep + os.environ.get("PATH", "")

    c_dir = ROOT / "outputs" / "c_run1"
    dll_path = args.out.resolve() / "mlp_demo.dll"
    subprocess.run([
        str(gcc), "-std=c99", "-O2", "-Wall", "-Wextra", "-Werror",
        "-shared", str(c_dir / "inference.c"), "-o", str(dll_path),
    ], check=True)

    library = ctypes.CDLL(str(dll_path))
    infer = library.mlp_infer
    infer.argtypes = [
        np.ctypeslib.ndpointer(np.uint8, ndim=1, flags="C_CONTIGUOUS"),
        np.ctypeslib.ndpointer(np.int32, ndim=1, flags="C_CONTIGUOUS"),
        np.ctypeslib.ndpointer(np.int8, ndim=1, flags="C_CONTIGUOUS"),
        np.ctypeslib.ndpointer(np.int32, ndim=1, flags="C_CONTIGUOUS"),
    ]
    infer.restype = ctypes.c_int

    acc1 = np.empty(16, dtype=np.int32)
    hidden = np.empty(16, dtype=np.int8)
    logits = np.empty(10, dtype=np.int32)
    prediction = int(infer(image, acc1, hidden, logits))

    print(f"MNIST test index : {args.index}")
    print(f"Image shape      : {image_2d.shape}")
    print(f"Flattened input  : {image.shape}, {image.dtype}, range {image.min()}..{image.max()}")
    print(f"True label       : {true_label}")
    print(f"C prediction     : {prediction}")
    print(f"Result           : {'CORRECT' if prediction == true_label else 'WRONG'}")
    print("Logits           : " + " ".join(f"{i}:{int(v)}" for i, v in enumerate(logits)))
    print(f"Preview saved to : {preview_path.resolve()}")


if __name__ == "__main__":
    main()
