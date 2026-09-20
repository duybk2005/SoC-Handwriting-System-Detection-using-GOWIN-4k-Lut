"""Export the integer MLP and reference vectors to standalone C99 sources.
Requires numpy and quantize_mlp.py beside this file. No training is performed.
"""
import argparse
import hashlib
import json
from pathlib import Path
import numpy as np
from quantize_mlp import integer_inference, accumulator_bound

ROOT = Path(__file__).resolve().parent

INFERENCE_H = '''#ifndef MLP_INFERENCE_H
#define MLP_INFERENCE_H
#include <stdint.h>
/* Input is raw row-major grayscale, no division by 255 here.
 * Buffers must have the lengths below. Returns first maximal class index. */
int mlp_infer(const uint8_t image[784], int32_t acc1[16],
              int8_t hidden[16], int32_t logits[10]);
#endif
'''

INFERENCE_C = '''#include "inference.h"
#include "weights.h"

int mlp_infer(const uint8_t image[784], int32_t acc1[16],
              int8_t hidden[16], int32_t logits[10])
{
    for (int j = 0; j < 16; ++j) {
        /* Exporter proves all partial sums fit INT32. */
        int32_t acc = B1[j];
        for (int i = 0; i < 784; ++i)
            acc += (int32_t)image[i] * (int32_t)W1[j][i];
        acc1[j] = acc;
        if (acc <= 0) {
            hidden[j] = 0;
        } else {
            /* Cast BEFORE multiplication. Shift only nonnegative values. */
            int64_t wide = (int64_t)acc * FC1_MULT;
            wide += INT64_C(1) << (FC1_SHIFT - 1);
            wide >>= FC1_SHIFT;
            if (wide > 127) wide = 127;
            hidden[j] = (int8_t)wide;
        }
    }
    for (int k = 0; k < 10; ++k) {
        int32_t acc = B2[k];
        for (int j = 0; j < 16; ++j)
            acc += (int32_t)hidden[j] * (int32_t)W2[k][j];
        logits[k] = acc;
    }
    int best = 0;
    for (int k = 1; k < 10; ++k)
        if (logits[k] > logits[best]) best = k;
    return best;
}
'''

MAIN_C = '''#include <stdio.h>
#include <inttypes.h>
#include "inference.h"
#include "test_vectors.h"

int main(void)
{
    int mismatches = 0, correct = 0;
    for (int n = 0; n < TEST_COUNT; ++n) {
        int32_t acc1[16], logits[10];
        int8_t hidden[16];
        int pred = mlp_infer(TEST_IMAGES[n], acc1, hidden, logits);
        for (int j = 0; j < 16; ++j) {
            if (acc1[j] != EXPECTED_ACC1[n][j]) {
                printf("MISMATCH image=%d acc1[%d]: C=%" PRId32 " Python=%" PRId32 "\\n",
                       n, j, acc1[j], EXPECTED_ACC1[n][j]);
                ++mismatches;
            }
            if (hidden[j] != EXPECTED_HIDDEN[n][j]) {
                printf("MISMATCH image=%d hidden[%d]\\n", n, j);
                ++mismatches;
            }
        }
        for (int k = 0; k < 10; ++k) {
            if (logits[k] != EXPECTED_LOGITS[n][k]) {
                printf("MISMATCH image=%d logits[%d]: C=%" PRId32 " Python=%" PRId32 "\\n",
                       n, k, logits[k], EXPECTED_LOGITS[n][k]);
                ++mismatches;
            }
        }
        if (pred != EXPECTED_CLASS[n]) {
            printf("MISMATCH image=%d class\\n", n);
            ++mismatches;
        }
        correct += (pred == TEST_LABELS[n]);
        if (n < 10)
            printf("Sample %d: label=%d, C=%d, Python=%d [%s]\\n",
                   n, (int)TEST_LABELS[n], pred, (int)EXPECTED_CLASS[n],
                   pred == TEST_LABELS[n] ? "CORRECT" : "WRONG LABEL");
    }
    printf("Checked %d images: acc1, hidden, logits, class\\n", TEST_COUNT);
    printf("C/Python mismatches: %d\\n", mismatches);
    printf("Label accuracy on these vectors: %d/%d\\n", correct, TEST_COUNT);
    if (mismatches) { puts("FAIL"); return 1; }
    puts("PASS: C matches Python integer exactly on all supplied vectors.");
    return 0;
}
'''


def c_array(name, a, ctype):
    dims = ''.join(f'[{n}]' for n in a.shape)
    def initializer(v):
        if v.ndim == 1:
            lines = [', '.join(str(int(x)) for x in v[i:i+16])
                     for i in range(0, len(v), 16)]
            return '{\n    ' + ',\n    '.join(lines) + '\n}'
        return '{\n' + ',\n'.join(initializer(row) for row in v) + '\n}'
    return f'static const {ctype} {name}{dims} = {initializer(a)};\n'


def read_npz(path):
    with np.load(path, allow_pickle=False) as f:
        return {key: f[key] for key in f.files}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--model', type=Path, default=ROOT/'outputs/int8_run1/mlp_int8.npz')
    parser.add_argument('--vectors', type=Path, default=ROOT/'outputs/int8_run1/reference_vectors.npz')
    parser.add_argument('--out', type=Path, default=ROOT/'outputs/c_run1')
    args = parser.parse_args()
    if args.out.exists() and any(args.out.iterdir()):
        raise ValueError('Output directory is not empty; choose a new --out.')
    p, v = read_npz(args.model), read_npz(args.vectors)
    for key, shape, dtype in [('w1',(16,784),np.int8), ('b1',(16,),np.int32),
                              ('w2',(10,16),np.int8), ('b2',(10,),np.int32)]:
        if p[key].shape != shape or p[key].dtype != dtype:
            raise ValueError(f'Unexpected shape or dtype: {key}')
    for key in ('mult', 'shift'):
        if p[key].shape != () or not np.issubdtype(p[key].dtype, np.integer):
            raise ValueError(f'{key} must be an integer scalar')
    mult, shift = int(p['mult']), int(p['shift'])
    if not (1 <= mult <= 2**31-1 and 1 <= shift <= 30):
        raise ValueError('Unsupported multiplier or shift.')
    bnd1 = accumulator_bound(p['w1'], p['b1'], 255)
    bnd2 = accumulator_bound(p['w2'], p['b2'], 127)
    n = len(v['images'])
    if not n or v['images'].shape != (n,28,28) or v['images'].dtype != np.uint8:
        raise ValueError('Expected nonempty UINT8 images [N,28,28].')
    if v['labels'].shape != (n,) or not np.issubdtype(v['labels'].dtype,np.integer):
        raise ValueError('Invalid label array')
    if np.any((v['labels'] < 0) | (v['labels'] > 9)):
        raise ValueError('Labels must be 0..9')
    got = integer_inference(v['images'], p)
    for key, actual in zip(('acc1','hidden','logits','predictions'),got):
        if not np.array_equal(actual,v[key]):
            raise ValueError(f'Model/reference mismatch in {key}; use matching files.')
    args.out.mkdir(parents=True, exist_ok=True)
    weights = '#ifndef MLP_WEIGHTS_H\n#define MLP_WEIGHTS_H\n#include <stdint.h>\n'
    weights += f'#define FC1_MULT INT32_C({mult})\n#define FC1_SHIFT {shift}\n'
    for key, ct in [('w1','int8_t'),('b1','int32_t'),('w2','int8_t'),('b2','int32_t')]:
        weights += c_array(key.upper(),p[key],ct)
    weights += '#endif\n'
    vectors = '#ifndef MLP_TEST_VECTORS_H\n#define MLP_TEST_VECTORS_H\n#include <stdint.h>\n'
    vectors += f'#define TEST_COUNT {n}\n'
    for name, arr, ct in [
        ('TEST_IMAGES',v['images'].reshape(n,784),'uint8_t'),
        ('TEST_LABELS',v['labels'],'uint8_t'),
        ('EXPECTED_ACC1',v['acc1'],'int32_t'),
        ('EXPECTED_HIDDEN',v['hidden'],'int8_t'),
        ('EXPECTED_LOGITS',v['logits'],'int32_t'),
        ('EXPECTED_CLASS',v['predictions'],'uint8_t')]:
        vectors += c_array(name, arr, ct)
    vectors += '#endif\n'
    for name, content in [('weights.h',weights), ('inference.h',INFERENCE_H),
                          ('inference.c',INFERENCE_C), ('test_vectors.h',vectors),
                          ('main.c',MAIN_C)]:
        (args.out/name).write_text(content,encoding='utf-8')
    manifest = dict(model_sha256=hashlib.sha256(args.model.read_bytes()).hexdigest(),
                    vectors_sha256=hashlib.sha256(args.vectors.read_bytes()).hexdigest(),
                    mult=mult,shift=shift,test_count=n,
                    bound_fc1=bnd1,bound_fc2=bnd2)
    (args.out/'export_manifest.json').write_text(json.dumps(manifest,indent=2),encoding='utf-8')
    print(f'Validated {n} Python reference vectors; accumulator bounds {bnd1}, {bnd2}')
    print(f'Exported to {args.out.resolve()}; mult={mult}, shift={shift}')
    print('Next: cd into output directory, compile and run:')
    print('gcc -std=c99 -O2 -Wall -Wextra -Werror inference.c main.c -o test_mlp.exe')
    print('Windows CMD: test_mlp.exe')


if __name__ == '__main__':
    main()
