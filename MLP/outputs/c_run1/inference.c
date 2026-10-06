#include "inference.h"
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
