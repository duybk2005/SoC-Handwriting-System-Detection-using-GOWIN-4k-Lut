#ifndef MLP_INFERENCE_H
#define MLP_INFERENCE_H
#include <stdint.h>
/* Input is raw row-major grayscale, no division by 255 here.
 * Buffers must have the lengths below. Returns first maximal class index. */
int mlp_infer(const uint8_t image[784], int32_t acc1[16],
              int8_t hidden[16], int32_t logits[10]);
#endif
