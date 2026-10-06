"""Verify existing C inference on all MNIST test images without a data header."""
import argparse
import ctypes
import hashlib
import json
import os
import subprocess
from pathlib import Path

import numpy as np
import torch
from torchvision.datasets import MNIST
from export_c import read_npz
from quantize_mlp import integer_inference, accumulator_bound
from train_mlp import MLP

ROOT = Path(__file__).resolve().parent


def sha(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def baseline_hashes():
    return {str(p.relative_to(ROOT)): sha(p)
            for name in ('run1', 'int8_run1', 'c_run1')
            for p in sorted((ROOT / 'outputs' / name).rglob('*')) if p.is_file()}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--gcc', default='C:/msys64/ucrt64/bin/gcc.exe')
    parser.add_argument('--out', type=Path, default=ROOT/'outputs/full_test_run1')
    args = parser.parse_args()
    if args.out.exists() and any(args.out.iterdir()):
        raise ValueError('Choose a new output directory.')
    before = baseline_hashes()
    args.out.mkdir(parents=True, exist_ok=True)
    # GCC subprocesses need the UCRT64 runtime DLLs on Windows PATH.
    gcc_dir = str(Path(args.gcc).resolve().parent)
    os.environ['PATH'] = gcc_dir + os.pathsep + os.environ.get('PATH', '')
    cdir = ROOT/'outputs/c_run1'
    flags = [args.gcc, '-std=c99', '-O2', '-Wall', '-Wextra', '-Werror']
    exe = args.out.resolve()/'test_100.exe'
    subprocess.run(flags + [str(cdir/'inference.c'), str(cdir/'main.c'), '-o', str(exe)], check=True)
    log = subprocess.run([str(exe)], check=True, capture_output=True, text=True).stdout
    (args.out/'test_100.txt').write_text(log, encoding='utf-8')
    dll = args.out.resolve()/'mlp.dll'
    subprocess.run(flags + ['-shared', str(cdir/'inference.c'), '-o', str(dll)], check=True)
    lib = ctypes.CDLL(str(dll))
    infer = lib.mlp_infer
    infer.argtypes = [np.ctypeslib.ndpointer(dtype=d, ndim=1, flags='C_CONTIGUOUS')
                      for d in (np.uint8, np.int32, np.int8, np.int32)]
    infer.restype = ctypes.c_int
    p = read_npz(ROOT/'outputs/int8_run1/mlp_int8.npz')
    bounds = [accumulator_bound(p['w1'], p['b1'], 255),
              accumulator_bound(p['w2'], p['b2'], 127)]
    assert (int(p['mult']), int(p['shift'])) == (435395, 30)
    test = MNIST(str(ROOT/'data'), train=False, download=False)
    images = test.data.numpy().reshape(-1, 784)
    labels = test.targets.numpy()
    assert images.shape == (10000, 784) and images.dtype == np.uint8
    ref = integer_inference(images, p)
    actual = [np.empty_like(a) for a in ref]
    for i, image in enumerate(images):
        actual[3][i] = infer(image, actual[0][i], actual[1][i], actual[2][i])
    mismatch = {key: int(np.count_nonzero(a != b)) for key, a, b in
                zip(('acc1', 'hidden', 'logits', 'predictions'), actual, ref)}
    bad = np.zeros(10000, dtype=bool)
    for a, b in zip(actual, ref):
        bad |= (a != b).reshape(10000, -1).any(axis=1)
    model = MLP().eval()
    ckpt = torch.load(ROOT/'outputs/run1/mlp_best.pt', map_location='cpu', weights_only=True)
    model.load_state_dict(ckpt['model_state_dict'], strict=True)
    with torch.inference_mode():
        fp = np.concatenate([model(torch.from_numpy(x.copy()).float()/255).argmax(1).numpy()
                             for x in np.array_split(images, 40)])
    # Persist predictions, not the whole dataset; source remains the local IDX files.
    np.savez(args.out/'predictions.npz', labels=labels, c=actual[3], python=ref[3], float=fp)
    after = baseline_hashes()
    report = dict(test_count=10000, c_correct=int((actual[3] == labels).sum()),
                  python_correct=int((ref[3] == labels).sum()),
                  float_correct=int((fp == labels).sum()),
                  float_integer_agreement=int((fp == ref[3]).sum()),
                  c_accuracy_percent=float((actual[3] == labels).mean()*100),
                  mismatches=mismatch, mismatched_images=int(bad.sum()),
                  accumulator_bounds=bounds, baseline_unchanged=before == after,
                  baseline_sha256=before, compiler=subprocess.check_output([args.gcc, '--version'], text=True),
                  data_sha256={p.name: sha(p) for p in (ROOT/'data/MNIST/raw').glob('t10k-*-ubyte')})
    (args.out/'verification_report.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    print(json.dumps({k: v for k, v in report.items() if k not in ('baseline_sha256', 'compiler', 'data_sha256')}, indent=2))
    if bad.any() or before != after:
        raise SystemExit('FAIL: mismatch or changed baseline')


if __name__ == '__main__':
    main()
