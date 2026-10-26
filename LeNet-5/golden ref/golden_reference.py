"""Standalone integer golden reference for the three brown LeNet-5 blocks.

Requires Python and NumPy only. All default paths are relative to this file.
Inputs are already patches P1/P2 and flattened V, not raw MNIST images.
"""
import argparse
import hashlib
import json
import re
import sys
from datetime import datetime, timezone
from pathlib import Path

import numpy as np

BASE = Path(__file__).resolve().parent
I32_MIN, I32_MAX, I64_MAX = -(1 << 31), (1 << 31) - 1, (1 << 63) - 1
SHAPES = {"c1": (6, 1, 5, 5), "c3": (16, 6, 5, 5),
          "c5": (120, 16, 5, 5), "f6": (84, 120), "output": (10, 84)}
INPUTS = {1: (np.uint8, (25, 784)), 2: (np.int8, (150, 100)), 3: (np.int8, (400, 1))}
OUTPUTS = {1: (np.int8, (6, 28, 28)), 2: (np.int8, (16, 10, 10)), 3: (np.int32, (10, 1))}


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def load_params(path):
    """Read frozen parameters, checking dtype, architecture and arithmetic bounds."""
    with np.load(path, allow_pickle=False) as source:
        params = {key: source[key].copy() for key in source.files}
    for layer, shape in SHAPES.items():
        w, b = params[layer + "_weight"], params[layer + "_bias"]
        require(w.dtype == np.int8 and w.shape == shape and np.all(w >= -127),
                f"Invalid {layer} weight: expected INT8 {shape}, range -127..127")
        require(b.dtype == np.int32 and b.shape == (shape[0],), f"Invalid {layer} bias")
        bounds = (255 if layer == "c1" else 127) * np.abs(w.astype(np.int64)).reshape(shape[0], -1).sum(1)
        bounds += np.abs(b.astype(np.int64))
        require(np.all(bounds <= I32_MAX), f"INT32 bound exceeded: {layer}")
        if layer != "output":
            mult, shift = params[layer + "_multiplier"], params[layer + "_shift"]
            require(mult.shape == shift.shape == () and mult.dtype == shift.dtype == np.int32,
                    f"Invalid {layer} requant scalar dtype/shape")
            require(1 <= int(mult) <= I32_MAX and 0 <= int(shift) <= 30, f"Invalid {layer} requant constants")
            offset = (1 << (int(shift) - 1)) if int(shift) else 0
            require(int(bounds.max()) * int(mult) + offset <= I64_MAX, f"INT64 bound exceeded: {layer}")
    return params


def affine(weight, x, bias):
    """INT8 weights, nonnegative 8-bit input; Python ints prevent silent wrap."""
    weight = weight.reshape(len(bias), -1)
    require(x.ndim == 2 and weight.shape[1] == x.shape[0], "MAC shape mismatch")
    result = np.empty((len(bias), x.shape[1]), np.int32)
    rows, columns = weight.tolist(), x.T.tolist()
    for o, row in enumerate(rows):
        for p, column in enumerate(columns):
            total = int(bias[o])
            for w, value in zip(row, column):
                total += w * value
                if not I32_MIN <= total <= I32_MAX:
                    raise OverflowError(f"INT32 partial-sum overflow: output={o}, position={p}")
            result[o, p] = total
    return result


def activate(acc, multiplier, shift):
    multiplier, shift = int(multiplier), int(shift)
    require(1 <= multiplier <= I32_MAX and 0 <= shift <= 30, "Invalid requant constants")
    offset = (1 << (shift - 1)) if shift else 0
    result = np.empty(acc.shape, np.int8)
    for i, value in enumerate(acc.flat):
        wide = max(int(value), 0) * multiplier + offset
        if wide > I64_MAX:
            raise OverflowError("INT64 requant overflow")
        result.flat[i] = min(wide >> shift, 127)
    return result


def block1(p1, params):
    acc1 = affine(params["c1_weight"], p1, params["c1_bias"])
    h1 = activate(acc1, params["c1_multiplier"], params["c1_shift"])
    return h1.reshape(6, 28, 28), {"c1_acc": acc1, "c1_activation": h1}


def block2(p2, params):
    acc2 = affine(params["c3_weight"], p2, params["c3_bias"])
    h2 = activate(acc2, params["c3_multiplier"], params["c3_shift"])
    return h2.reshape(16, 10, 10), {"c3_acc": acc2, "c3_activation": h2}


def block3(v, params):
    acc3 = affine(params["c5_weight"], v, params["c5_bias"])
    h3 = activate(acc3, params["c5_multiplier"], params["c5_shift"])
    acc4 = affine(params["f6_weight"], h3, params["f6_bias"])
    h4 = activate(acc4, params["f6_multiplier"], params["f6_shift"])
    logits = affine(params["output_weight"], h4, params["output_bias"])
    return logits, {"c5_acc": acc3, "c5_activation": h3, "f6_acc": acc4,
                    "f6_activation": h4, "output_acc": logits}


def calculate(number, x, params):
    dtype, shape = INPUTS[number]
    require(x.shape == shape and x.dtype == dtype, f"Invalid block {number} input descriptor")
    require(np.all(x >= 0) and (number == 1 or np.all(x <= 127)), "Input activation outside valid range")
    return {1: block1, 2: block2, 3: block3}[number](x, params)


def read_hex(path, dtype, shape_per_sample):
    """Infer sample count from word count. Decode signed words as two's complement."""
    dtype = np.dtype(dtype)
    require(dtype in (np.dtype("uint8"), np.dtype("int8"), np.dtype("int32")), "Unsupported dtype")
    bits = dtype.itemsize * 8
    lines = Path(path).read_text(encoding="ascii").splitlines()
    words = int(np.prod(shape_per_sample))
    require(lines and len(lines) % words == 0,
            f"{Path(path).name}: word count {len(lines)} is not a positive multiple of {words}")
    values = []
    for i, line in enumerate(lines):
        require(re.fullmatch(r"[0-9a-fA-F]{" + str(bits // 4) + "}", line) is not None,
                f"{Path(path).name}: invalid hex word on line {i + 1}")
        value = int(line, 16)
        if dtype.kind == "i" and value >= (1 << (bits - 1)):
            value -= 1 << bits
        values.append(value)
    return np.array(values, dtype=dtype).reshape((len(lines) // words,) + tuple(shape_per_sample))


def write_hex(path, array):
    bits = array.dtype.itemsize * 8
    with Path(path).open("x", encoding="ascii", newline="\n") as file:
        for value in array.flat:
            file.write(f"{int(value) & ((1 << bits) - 1):0{bits // 4}x}\n")
    decoded = read_hex(path, array.dtype, array.shape[1:])
    require(np.array_equal(decoded, array), "Output hex round-trip mismatch")


def compare(actual, expected):
    require(actual.shape == expected.shape and actual.dtype == expected.dtype, "Expected output shape/dtype mismatch")
    delta = actual.astype(np.int64) - expected.astype(np.int64)
    positions = np.flatnonzero(delta)
    first = None
    if positions.size:
        index = int(positions[0])
        first = dict(word_index=index, line=index + 1,
                     sample=index // int(actual[0].size),
                     position=list(map(int, np.unravel_index(index, actual.shape)[1:])),
                     expected=int(expected.flat[index]), actual=int(actual.flat[index]))
    return dict(elements=int(actual.size), mismatches=int(positions.size),
                max_absolute_difference=int(np.abs(delta).max()), first_mismatch=first)


def run(params_path, input_dir, expected_dir, numbers, out):
    params = load_params(params_path)
    # Read and validate all requested files before writing any result.
    jobs = []
    for number in numbers:
        ipath = input_dir / f"block{number}_I.hex"
        x = read_hex(ipath, *INPUTS[number])
        require(np.all(x >= 0) and (number == 1 or np.all(x <= 127)), f"Block {number}: invalid input range")
        opath = expected_dir / f"block{number}_O.hex" if expected_dir is not None else None
        expected = read_hex(opath, *OUTPUTS[number]) if opath is not None else None
        require(expected is None or len(expected) == len(x), f"Block {number}: input/output sample count mismatch")
        jobs.append((number, ipath, x, opath, expected))
    out.mkdir(parents=True, exist_ok=False)
    report = dict(status="GENERATED", compared_with_expected=expected_dir is not None,
                  model_sha256=sha(params_path), script_sha256=sha(__file__), blocks={},
                  scope="Python golden reference only; no RTL simulation or full-test accuracy evaluation.")
    all_match = True
    for number, ipath, inputs, opath, expected in jobs:
        outputs, traces = [], {}
        for value in inputs:
            result, trace = calculate(number, value, params)
            outputs.append(result)
            for name, tensor in trace.items():
                traces.setdefault(name, []).append(tensor)
        outputs = np.stack(outputs)
        destination = out / f"block{number}_O.hex"
        write_hex(destination, outputs)
        np.savez_compressed(out / f"block{number}_trace.npz", **{k: np.stack(v) for k, v in traces.items()})
        row = dict(samples=len(inputs), input_sha256=sha(ipath), output_sha256=sha(destination),
                   output_words=int(outputs.size), output_dtype=str(outputs.dtype),
                   output_shape=list(outputs.shape), roundtrip_passed=True)
        if expected is not None:
            row["comparison"] = compare(outputs, expected)
            row["expected_sha256"] = sha(opath)
            mismatches = row["comparison"]["mismatches"]
            all_match = all_match and mismatches == 0
            print(f"Block {number}: {'PASS' if mismatches == 0 else 'FAIL'}, {len(inputs)} samples, {mismatches} mismatches")
            if mismatches:
                print("  First mismatch:", row["comparison"]["first_mismatch"])
        else:
            print(f"Block {number}: GENERATED, {len(inputs)} samples, {outputs.size} output words")
        report["blocks"][str(number)] = row
    report["status"] = ("PASS" if all_match else "FAIL") if expected_dir is not None else "GENERATED"
    (out / "verification_report.json").write_text(json.dumps(report, indent=2) + "\n", encoding="utf-8")
    print("Results:", out)
    return 0 if all_match else 1


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--params", type=Path, default=BASE / "model_params.npz")
    parser.add_argument("--input-dir", type=Path, default=BASE)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--expected-dir", type=Path, default=BASE, help="Directory with reference O.hex files")
    group.add_argument("--no-compare", action="store_true", help="Generate outputs for new inputs without comparison")
    parser.add_argument("--block", choices=("all", "1", "2", "3"), default="all")
    parser.add_argument("--out", type=Path, help="New result directory; default next to this script")
    args = parser.parse_args()
    stamp = datetime.now(timezone.utc).strftime("%Y%m%d_%H%M%S_%fZ")
    numbers = (1, 2, 3) if args.block == "all" else (int(args.block),)
    try:
        return run(args.params.resolve(), args.input_dir.resolve(),
                   None if args.no_compare else args.expected_dir.resolve(), numbers,
                   args.out.resolve() if args.out else BASE / ("results_" + stamp))
    except (ValueError, KeyError, OSError, OverflowError) as error:
        print(f"ERROR: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
