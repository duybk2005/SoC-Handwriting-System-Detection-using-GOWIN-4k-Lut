"""Integer-only inference for LeNet-5 B (NumPy INT64 checked reference)."""
from pathlib import Path

import numpy as np

LAYERS = ("c1", "c3", "c5", "f6", "output")
SHAPES = {"c1": (6, 1, 5, 5), "c3": (16, 6, 5, 5),
          "c5": (120, 16, 5, 5), "f6": (84, 120), "output": (10, 84)}
I32_MIN, I32_MAX, I64_MAX = -(2**31), 2**31 - 1, 2**63 - 1


def round_away(values):
    values = np.asarray(values, dtype=np.float64)
    return np.sign(values) * np.floor(np.abs(values) + 0.5)


def ratio_multiplier(ratio):
    if not np.isfinite(ratio) or ratio <= 0:
        raise ValueError("Invalid requant ratio")
    for shift in range(30, -1, -1):
        mult = int(np.floor(ratio * (1 << shift) + 0.5))
        if 1 <= mult <= I32_MAX:
            return mult, shift
    raise ValueError("Cannot represent ratio as positive signed INT32 multiplier")


def checked_i32(values):
    if values.min() < I32_MIN or values.max() > I32_MAX:
        raise OverflowError("Accumulator exceeds INT32")
    return values.astype(np.int32)


def conv_acc(x, weight, bias):
    """Cross-correlation, stride 1, no padding, OIHW weights; no floating MAC."""
    kh, kw = weight.shape[2:]
    windows = np.lib.stride_tricks.sliding_window_view(x, (kh, kw), axis=(2, 3))
    n, c, h, w, _, _ = windows.shape
    # One row per spatial position, reduction order in_channel/kernel_y/kernel_x.
    rows = windows.transpose(0, 2, 3, 1, 4, 5).reshape(n*h*w, c*kh*kw).astype(np.int64)
    result = rows @ weight.reshape(weight.shape[0], -1).astype(np.int64).T
    result += bias.astype(np.int64)
    return checked_i32(result.reshape(n, h, w, weight.shape[0]).transpose(0, 3, 1, 2))


def linear_acc(x, weight, bias):
    return checked_i32(x.astype(np.int64) @ weight.astype(np.int64).T + bias.astype(np.int64))


def requant(acc, multiplier, shift):
    multiplier, shift = int(multiplier), int(shift)
    if not (1 <= multiplier <= I32_MAX and 0 <= shift <= 30):
        raise ValueError("Invalid multiplier/shift")
    positive = np.maximum(acc.astype(np.int64), 0)
    offset = (1 << (shift-1)) if shift else 0
    if int(positive.max()) * multiplier + offset > I64_MAX:
        raise OverflowError("INT64 requant multiply overflows")
    wide = (positive * multiplier + offset) >> shift
    stats = dict(count=acc.size, negative_relu=int(np.count_nonzero(acc < 0)),
                 accumulator_zero=int(np.count_nonzero(acc == 0)),
                 upper_saturated=int(np.count_nonzero(wide > 127)),
                 output_zero=int(np.count_nonzero(wide == 0)))
    return np.clip(wide, 0, 127).astype(np.int8), stats


def max_pool(x):
    n, c, h, w = x.shape
    if h % 2 or w % 2:
        raise ValueError("Pool dimensions must be even")
    return x.reshape(n, c, h//2, 2, w//2, 2).max(axis=(3, 5))


def validate_model(params):
    expected_keys = set()
    previous_scale = 1 / 255
    for layer in LAYERS:
        keys = [f"{layer}_{k}" for k in ("weight", "bias", "input_scale", "weight_scale", "accumulator_scale")]
        if layer != "output":
            keys += [f"{layer}_{k}" for k in ("output_scale", "multiplier", "shift")]
        expected_keys.update(keys)
        w, b = params[f"{layer}_weight"], params[f"{layer}_bias"]
        if w.dtype != np.int8 or w.shape != SHAPES[layer] or np.any(w < -127):
            raise ValueError(f"Invalid {layer} weight")
        if b.dtype != np.int32 or b.shape != (SHAPES[layer][0],):
            raise ValueError(f"Invalid {layer} bias")
        for key in ("input_scale", "weight_scale", "accumulator_scale"):
            value = params[f"{layer}_{key}"]
            if value.shape != () or not np.isfinite(value) or value <= 0:
                raise ValueError(f"Invalid {layer} {key}")
        if float(params[f"{layer}_input_scale"]) != previous_scale:
            raise ValueError("Scale continuity mismatch")
        if float(params[f"{layer}_accumulator_scale"]) != previous_scale * float(params[f"{layer}_weight_scale"]):
            raise ValueError("Bias/accumulator scale mismatch")
        if layer != "output":
            previous_scale = float(params[f"{layer}_output_scale"])
            if not np.isfinite(previous_scale) or previous_scale <= 0:
                raise ValueError("Invalid activation scale")
            mult, shift = params[f"{layer}_multiplier"], params[f"{layer}_shift"]
            if mult.dtype != np.int32 or shift.dtype != np.int32 or mult.shape != () or shift.shape != ():
                raise ValueError("Multiplier/shift must be scalar INT32")
            if not (1 <= int(mult) <= I32_MAX and 0 <= int(shift) <= 30):
                raise ValueError("Invalid multiplier/shift")
    if set(params) != expected_keys:
        raise ValueError("Unexpected/missing model tensors")


def model_bounds(params):
    validate_model(params)
    report = {}
    for layer in LAYERS:
        w = params[f"{layer}_weight"].astype(np.int64).reshape(SHAPES[layer][0], -1)
        b = params[f"{layer}_bias"].astype(np.int64)
        input_max = 255 if layer == "c1" else 127
        bounds = input_max * np.abs(w).sum(axis=1) + np.abs(b)
        if np.any(bounds > I32_MAX):
            raise OverflowError(f"{layer} static bound exceeds INT32")
        entry = dict(input_max=input_max, per_channel=bounds.tolist(), max=int(bounds.max()),
                     max_abs_bias=int(np.abs(b).max()), int32_safe=True,
                     covers_partial_sums=True)
        if layer != "output":
            mult, shift = int(params[f"{layer}_multiplier"]), int(params[f"{layer}_shift"])
            offset = (1 << (shift-1)) if shift else 0
            wide = int(bounds.max()) * mult + offset
            if wide > I64_MAX:
                raise OverflowError(f"{layer} static requant exceeds INT64")
            entry.update(requant_int64_bound=wide, int64_safe=True)
        report[layer] = entry
    return report


def inference(raw, params, intermediates=False):
    raw = np.asarray(raw)
    if raw.dtype != np.uint8 or raw.ndim != 3 or raw.shape[1:] != (28, 28) or not len(raw):
        raise ValueError("Expected nonempty raw UINT8 [N,28,28]")
    x = np.pad(raw[:, None], ((0, 0), (0, 0), (2, 2), (2, 2)))
    trace, stats = {"input": x}, {}
    for layer in LAYERS:
        w, b = params[f"{layer}_weight"], params[f"{layer}_bias"]
        acc = conv_acc(x, w, b) if layer.startswith("c") else linear_acc(x, w, b)
        if intermediates:
            trace[f"{layer}_acc"] = acc
        if layer == "output":
            logits = acc
            break
        x, stats[layer] = requant(acc, params[f"{layer}_multiplier"], params[f"{layer}_shift"])
        if intermediates:
            trace[f"{layer}_activation"] = x
        if layer in ("c1", "c3"):
            x = max_pool(x)
            if intermediates:
                trace["s2" if layer == "c1" else "s4"] = x
        if layer == "c5":
            x = x.reshape(len(raw), 120)
            if intermediates:
                trace["flatten"] = x
    predictions = logits.argmax(axis=1)
    if intermediates:
        trace.update(logits=logits, predictions=predictions)
    return logits, predictions, stats, trace if intermediates else None


def run_dataset(raw, params, batch_size=32, progress=None):
    model_bounds(params)
    all_logits, all_predictions, stats = [], [], {}
    for start in range(0, len(raw), batch_size):
        logits, predictions, batch_stats, _ = inference(raw[start:start+batch_size], params)
        all_logits.append(logits)
        all_predictions.append(predictions)
        for layer, values in batch_stats.items():
            target = stats.setdefault(layer, {key: 0 for key in values})
            for key, value in values.items():
                target[key] += value
        if progress and ((start//batch_size) % 50 == 0 or start+batch_size >= len(raw)):
            progress(min(start+batch_size, len(raw)), len(raw))
    for values in stats.values():
        values.update(negative_relu_percent=100*values["negative_relu"]/values["count"],
                      upper_saturation_percent=100*values["upper_saturated"]/values["count"],
                      denominator="All pre-pooling activation elements after this affine layer")
    return np.concatenate(all_logits), np.concatenate(all_predictions), stats


def load_model(path):
    with np.load(Path(path), allow_pickle=False) as file:
        params = {key: file[key].copy() for key in file.files}
    model_bounds(params)
    return params


def self_check():
    np.testing.assert_array_equal(round_away([-1.5, -.5, .5, 1.5]), [-2, -1, 1, 2])
    q, _ = requant(np.array([-1, 0, 1, 3, 5, 255, 257], np.int32), 1, 1)
    np.testing.assert_array_equal(q, [0, 0, 1, 2, 3, 127, 127])
    q, stats = requant(np.array([-1, 0, 127, 128], np.int32), 1, 0)
    np.testing.assert_array_equal(q, [0, 0, 127, 127])
    assert stats["negative_relu"] == 1 and stats["upper_saturated"] == 1
    q, _ = requant(np.array([I32_MAX], np.int32), I32_MAX, 30)
    assert q.item() == 127
    for ratio in (0.001, 0.25, 1., 3.):
        m, s = ratio_multiplier(ratio)
        assert abs(m/(1 << s) - ratio) <= .5/(1 << s) + 1e-15
    rng = np.random.default_rng(42)
    x = rng.integers(0, 256, (2, 2, 7, 8), dtype=np.uint8)
    w = rng.integers(-127, 128, (3, 2, 3, 3), dtype=np.int16).astype(np.int8)
    b = np.array([-23, 0, 17], np.int32)
    actual = conv_acc(x, w, b)
    expected = np.empty_like(actual)
    for n in range(2):
        for o in range(3):
            for y in range(5):
                for z in range(6):
                    expected[n, o, y, z] = int(b[o]) + sum(
                        int(x[n, c, y+ky, z+kx]) * int(w[o, c, ky, kx])
                        for c in range(2) for ky in range(3) for kx in range(3))
    np.testing.assert_array_equal(actual, expected)
    pooled_input = rng.integers(0, 128, (2, 3, 6, 8), dtype=np.int8)
    pool_expected = np.empty((2, 3, 3, 4), np.int8)
    for y in range(3):
        for z in range(4):
            pool_expected[:, :, y, z] = pooled_input[:, :, y*2:y*2+2, z*2:z*2+2].max(axis=(2, 3))
    np.testing.assert_array_equal(max_pool(pooled_input), pool_expected)
    flatten_x = np.arange(400).reshape(1, 16, 5, 5)
    np.testing.assert_array_equal(flatten_x.reshape(1, -1), np.arange(400)[None])
    assert np.array([[4, 4, -1]], np.int32).argmax(1).item() == 0
    return dict(passed=True, rounding_signed_half=True, relu_requant_boundaries=True,
                shift_zero=True, int64_large_multiply=True, multiplier_error=True,
                conv_matches_naive_multichannel_signed_weights=True,
                max_pool_matches_naive=True, flatten_row_major=True, first_argmax_tie=True)
