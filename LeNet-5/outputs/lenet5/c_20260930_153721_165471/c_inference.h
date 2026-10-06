#ifndef LENET5_C_INFERENCE_H
#define LENET5_C_INFERENCE_H
#include <stddef.h>
#include <stdint.h>
#if defined(_WIN32)
#define LENET_API __declspec(dllexport)
#else
#define LENET_API
#endif

enum { LENET_OK=0, LENET_NULL=-1, LENET_SIZE=-2, LENET_RANGE=-3 };
enum { LENET_U8=1, LENET_I8=2, LENET_I32=3 };
/* Caller owns an aligned workspace. All fields are contiguous CHW arrays.
 * Each concurrent call needs separate workspace and output buffers. */
typedef struct {
    uint8_t input[1024];
    int32_t c1_acc[4704];
    int8_t c1_activation[4704], s2[1176];
    int32_t c3_acc[1600];
    int8_t c3_activation[1600], s4[400];
    int32_t c5_acc[120];
    int8_t c5_activation[120], flatten[120];
    int32_t f6_acc[84];
    int8_t f6_activation[84];
    int32_t output_acc[10], predictions[1];
} lenet_workspace;

LENET_API size_t lenet_workspace_size(void);
/* raw_len must be 784; logits_count must be 10; workspace_bytes >= sizeof.
 * Non-null buffers must be valid for declared sizes, aligned, and disjoint.
 * Invalid argument errors leave all outputs/workspace unchanged. */
LENET_API int lenet_infer(const uint8_t *raw, size_t raw_len,
    lenet_workspace *work, size_t workspace_bytes,
    int32_t *logits, size_t logits_count, int32_t *class_id);
/* Read-only tensor pointer into workspace, valid until next inference there.
 * IDs 0..14 match the trace schema documented in C_SPEC.md. */
LENET_API const void *lenet_trace(const lenet_workspace *work, int id,
    size_t *count, int *dtype);
/* Read-only parameters compiled into this DLL. Layer IDs 0..4, kind:
 * 0=weight, 1=bias, 2=multiplier, 3=shift. Output has no requant. */
LENET_API const void *lenet_parameter(int layer, int kind,
    size_t *count, int *dtype);

/* Diagnostic primitives use the same kernels as inference; conv checks a
 * conservative input<=255 bound before MAC. Caller supplies correctly sized
 * buffers, dimensions <=32, channels/output_channels <=120. */
LENET_API int lenet_debug_conv(const uint8_t *x, const int8_t *w,
    const int32_t *b, int channels, int h, int width, int outputs,
    int kh, int kw, int32_t *acc);
LENET_API int lenet_debug_pool(const int8_t *x, int channels, int h,
    int width, int8_t *out);
LENET_API int lenet_debug_requant(int32_t acc, int32_t multiplier,
    int shift, int8_t *out);
LENET_API int lenet_debug_argmax(const int32_t *logits, size_t count,
    int32_t *class_id);
#endif
