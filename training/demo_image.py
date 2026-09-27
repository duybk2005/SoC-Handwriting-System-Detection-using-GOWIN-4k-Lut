"""Recognize an external image using the existing C MLP, without retraining."""
import argparse
import ctypes
from datetime import datetime
import hashlib
import html
import json
import os
from pathlib import Path
import subprocess

import numpy as np
from PIL import Image, ImageOps
from quantize_mlp import integer_inference

ROOT = Path(__file__).resolve().parent


def prepare(source, ready=False):
    gray = ImageOps.exif_transpose(source).convert('L')
    if ready:
        if gray.size != (28, 28):
            raise ValueError('--ready requires a 28x28 image, bright digit on black.')
        return gray
    a = np.asarray(gray)
    # Otsu threshold: separate ink and a reasonably uniform background.
    hist = np.bincount(a.ravel(), minlength=256).astype(float)
    count = np.cumsum(hist)
    moment = np.cumsum(hist * np.arange(256))
    denominator = count * (a.size - count)
    score = np.zeros(256)
    valid = denominator > 0
    score[valid] = (moment[-1] * count[valid] - moment[valid] * a.size)**2 / denominator[valid]
    threshold = int(np.argmax(score))
    border = np.concatenate((a[0], a[-1], a[:, 0], a[:, -1]))
    ink = a <= threshold if np.median(border) > threshold else a > threshold
    ys, xs = np.nonzero(ink)
    if not len(xs) or ink.all():
        raise ValueError('No foreground/background separation; use a clear single digit.')
    digit = Image.fromarray((ink * 255).astype(np.uint8)).crop(
        (int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1))
    factor = 20 / max(digit.size)
    digit = digit.resize(tuple(max(1, round(s * factor)) for s in digit.size), Image.Resampling.LANCZOS)
    arr = np.asarray(digit, dtype=float)
    yy, xx = np.indices(arr.shape)
    cx, cy = (xx * arr).sum() / arr.sum(), (yy * arr).sum() / arr.sum()
    left = min(28 - digit.width, max(0, round(13.5 - cx)))
    top = min(28 - digit.height, max(0, round(13.5 - cy)))
    canvas = Image.new('L', (28, 28), 0)
    canvas.paste(digit, (left, top))
    return canvas


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--image', type=Path, default=ROOT / 'demo_assets/handwritten_seven_original.jpg')
    parser.add_argument('--ready', action='store_true', help='Use an already prepared 28x28 image unchanged.')
    parser.add_argument('--label', type=int, choices=range(10), help='Optional expected label, for reporting only.')
    parser.add_argument('--out', type=Path)
    parser.add_argument('--gcc', type=Path, default=Path('C:/msys64/ucrt64/bin/gcc.exe'))
    args = parser.parse_args()
    with Image.open(args.image) as source:
        original = ImageOps.exif_transpose(source).convert('RGB')
        prepared = prepare(source, args.ready)
    out = (args.out or ROOT / 'outputs' / ('external_demo_' + datetime.now().strftime('%Y%m%d_%H%M%S_%f'))).resolve()
    if out.exists() and any(out.iterdir()):
        raise FileExistsError(f'Refusing to overwrite nonempty directory: {out}')
    out.mkdir(parents=True, exist_ok=True)
    original.save(out / 'original.png')
    prepared.save(out / 'input_28x28.png')
    prepared.resize((280, 280), Image.Resampling.NEAREST).save(out / 'input_preview.png')
    pixels = np.ascontiguousarray(np.asarray(prepared).reshape(784), dtype=np.uint8)
    pixels.tofile(out / 'input_uint8.bin')
    os.environ['PATH'] = str(args.gcc.parent.resolve()) + os.pathsep + os.environ.get('PATH', '')
    dll = out / 'mlp_demo.dll'
    subprocess.run([str(args.gcc), '-std=c99', '-O2', '-Wall', '-Wextra', '-Werror',
                    '-shared', str(ROOT / 'outputs/c_run1/inference.c'), '-o', str(dll)], check=True)
    library = ctypes.CDLL(str(dll))
    infer = library.mlp_infer
    infer.argtypes = [np.ctypeslib.ndpointer(t, ndim=1, flags='C_CONTIGUOUS')
                     for t in (np.uint8, np.int32, np.int8, np.int32)]
    infer.restype = ctypes.c_int
    acc1, hidden, logits = np.empty(16, np.int32), np.empty(16, np.int8), np.empty(10, np.int32)
    prediction = int(infer(pixels, acc1, hidden, logits))
    with np.load(ROOT / 'outputs/int8_run1/mlp_int8.npz', allow_pickle=False) as model:
        reference = integer_inference(pixels.reshape(1, 28, 28), model)
    actual = (acc1, hidden, logits, np.asarray(prediction))
    mismatches = {name: int(np.count_nonzero(value != expected[0]))
                  for name, value, expected in zip(('acc1', 'hidden', 'logits', 'class'), actual, reference)}
    if any(mismatches.values()):
        raise AssertionError(f'C/Python mismatch: {mismatches}')
    report = dict(image=str(args.image.resolve()), prediction=prediction, expected_label=args.label,
                  correct=None if args.label is None else prediction == args.label,
                  input_bytes=int(pixels.nbytes), input_sha256=hashlib.sha256(pixels.tobytes()).hexdigest(),
                  ready=args.ready, mismatches=mismatches, acc1=acc1.tolist(), hidden=hidden.tolist(), logits=logits.tolist())
    (out / 'result.json').write_text(json.dumps(report, indent=2), encoding='utf-8')
    rows = ''.join(f'<tr><td>{i}</td><td>{int(v)}</td></tr>' for i, v in enumerate(logits))
    page = f'''<!doctype html><html lang="vi"><meta charset="utf-8"><title>Demo MLP trên laptop</title>
<style>body{{font:20px system-ui;background:#f3f5fa;color:#19283e;max-width:1000px;margin:40px auto;padding:20px}}.cards{{display:flex;gap:24px;flex-wrap:wrap}}section{{background:white;padding:24px;border-radius:16px;flex:1}}img{{width:240px;height:280px;object-fit:contain}}.pixel{{image-rendering:pixelated}}.number{{font-size:110px;font-weight:800;color:#176c50;margin:10px 0}}td{{padding:5px 25px}}small{{font-size:15px}}</style>
<h1>Nhận dạng chữ số bằng MLP 784 → 16 → 10</h1>
<p>Demo ảnh ngoài MNIST · inference C trên laptop</p><div class="cards">
<section><h2>1. Ảnh gốc</h2><img src="original.png"><p>{html.escape(args.image.name)}</p></section>
<section><h2>2. Đầu vào mạng</h2><img class="pixel" src="input_preview.png"><p>28×28 · UINT8 · 784 byte</p></section>
<section><h2>3. C dự đoán</h2><p class="number">{prediction}</p><p>Nhãn kỳ vọng: {args.label if args.label is not None else 'chưa cung cấp'}</p><p>C/Python khớp cả 4 đầu ra.</p></section></div>
<p>Ảnh → tiền xử lý Python → buffer 784 pixel → mạng C → argmax</p>
<details><summary>Xem 10 logits (điểm số, không phải phần trăm)</summary><table>{rows}</table></details>
<p><small>Đây là một mẫu demo, không phải phép đo accuracy ngoài MNIST. Chưa chạy trên FPGA.</small></p>
<p><small>Ảnh mẫu mặc định: <a href="https://commons.wikimedia.org/wiki/File:Handwritten_number_seven.jpg">Incompetencia / Wikimedia Commons</a>, <a href="https://creativecommons.org/licenses/by-sa/4.0/">CC BY-SA 4.0</a>. Bản xử lý: grayscale, tách nền, đổi kích thước, căn giữa; cùng giấy phép.</small></p></html>'''
    (out / 'demo.html').write_text(page, encoding='utf-8')
    print(f'Input: {args.image}\nShape: 28x28 -> 784 UINT8 pixels ({pixels.nbytes} bytes)')
    print(f'C prediction: {prediction}\nExpected label: {args.label}\nC/Python mismatches: {mismatches}')
    print(f'Logits: {logits.tolist()}\nDemo page: {out / "demo.html"}')


if __name__ == '__main__':
    main()
