#include <stdio.h>
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
                printf("MISMATCH image=%d acc1[%d]: C=%" PRId32 " Python=%" PRId32 "\n",
                       n, j, acc1[j], EXPECTED_ACC1[n][j]);
                ++mismatches;
            }
            if (hidden[j] != EXPECTED_HIDDEN[n][j]) {
                printf("MISMATCH image=%d hidden[%d]\n", n, j);
                ++mismatches;
            }
        }
        for (int k = 0; k < 10; ++k) {
            if (logits[k] != EXPECTED_LOGITS[n][k]) {
                printf("MISMATCH image=%d logits[%d]: C=%" PRId32 " Python=%" PRId32 "\n",
                       n, k, logits[k], EXPECTED_LOGITS[n][k]);
                ++mismatches;
            }
        }
        if (pred != EXPECTED_CLASS[n]) {
            printf("MISMATCH image=%d class\n", n);
            ++mismatches;
        }
        correct += (pred == TEST_LABELS[n]);
        if (n < 10)
            printf("Sample %d: label=%d, C=%d, Python=%d [%s]\n",
                   n, (int)TEST_LABELS[n], pred, (int)EXPECTED_CLASS[n],
                   pred == TEST_LABELS[n] ? "CORRECT" : "WRONG LABEL");
    }
    printf("Checked %d images: acc1, hidden, logits, class\n", TEST_COUNT);
    printf("C/Python mismatches: %d\n", mismatches);
    printf("Label accuracy on these vectors: %d/%d\n", correct, TEST_COUNT);
    if (mismatches) { puts("FAIL"); return 1; }
    puts("PASS: C matches Python integer exactly on all supplied vectors.");
    return 0;
}
