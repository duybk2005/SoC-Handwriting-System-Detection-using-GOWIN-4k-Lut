"""Verify copied files and 17 integer references; this is not a full-test run."""
import hashlib
import json
from pathlib import Path
import numpy as np
from lenet5.integer import load_model, inference

ROOT = Path(__file__).resolve().parent

def main():
    manifest = json.loads((ROOT / "HANDOFF_MANIFEST.json").read_text(encoding="utf-8"))
    for name, expected in manifest["sha256"].items():
        p = ROOT / name
        if not p.is_file() or hashlib.sha256(p.read_bytes()).hexdigest() != expected:
            raise RuntimeError(f"File missing or changed: {name}")
    mem = ROOT / "outputs/lenet5/mem_20260930_173742_222887"
    def words(name, dtype):
        return np.array([int(s, 16) for s in (mem / name).read_text(encoding="ascii").splitlines()], dtype=dtype)
    raw = words("reference_raw_input.mem", np.uint8).reshape(-1, 28, 28)
    expected_logits = words("reference_logits.mem", np.uint32).view(np.int32).reshape(-1, 10)
    expected_class = words("reference_class.mem", np.uint8)
    params = load_model(ROOT / "outputs/lenet5/int8_20260930_145802_710572/lenet5_int8.npz")
    logits, classes, _, _ = inference(raw, params)
    if not np.array_equal(logits, expected_logits) or not np.array_equal(classes, expected_class):
        raise RuntimeError("Integer reference logits/class mismatch")
    print(f"PASS: {len(manifest['sha256'])} file hashes; {len(raw)} integer reference logits/classes match.")
    print("This handoff check does not replace the saved 10,000-image full-test reports.")

if __name__ == "__main__":
    main()
