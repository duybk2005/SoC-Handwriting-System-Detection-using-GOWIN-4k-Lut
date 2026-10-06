#ifndef LENET5_MODEL_PARAMS_H
#define LENET5_MODEL_PARAMS_H
#include <stdint.h>
extern const int8_t LENET_C1_WEIGHT[150];
extern const int32_t LENET_C1_BIAS[6];
#define LENET_C1_MULTIPLIER INT32_C(1669522)
#define LENET_C1_SHIFT INT32_C(30)
extern const int8_t LENET_C3_WEIGHT[2400];
extern const int32_t LENET_C3_BIAS[16];
#define LENET_C3_MULTIPLIER INT32_C(2616330)
#define LENET_C3_SHIFT INT32_C(30)
extern const int8_t LENET_C5_WEIGHT[48000];
extern const int32_t LENET_C5_BIAS[120];
#define LENET_C5_MULTIPLIER INT32_C(1981865)
#define LENET_C5_SHIFT INT32_C(30)
extern const int8_t LENET_F6_WEIGHT[10080];
extern const int32_t LENET_F6_BIAS[84];
#define LENET_F6_MULTIPLIER INT32_C(3025526)
#define LENET_F6_SHIFT INT32_C(30)
extern const int8_t LENET_OUTPUT_WEIGHT[840];
extern const int32_t LENET_OUTPUT_BIAS[10];
#endif
