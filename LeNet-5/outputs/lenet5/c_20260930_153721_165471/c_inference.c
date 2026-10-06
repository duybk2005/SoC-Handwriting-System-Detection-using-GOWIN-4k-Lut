#include "c_inference.h"
#include "model_params.h"
#include <limits.h>
#include <string.h>

_Static_assert(CHAR_BIT == 8 && sizeof(int32_t) == 4 && sizeof(int64_t) == 8,
               "Requires 8-bit bytes, exact 32/64-bit integers");

/* Input is a nonnegative byte. For hidden int8_t values 0..127, reading the
 * object representation through uint8_t (unsigned char on this toolchain)
 * preserves its numeric value. Exporter proves all INT32 partial sums safe. */
static void conv(const uint8_t *x, const int8_t *w, const int32_t *b,
    int channels, int h, int width, int outputs, int kh, int kw, int32_t *out)
{
    const int oh=h-kh+1, ow=width-kw+1;
    for (int o=0; o<outputs; ++o)
        for (int y=0; y<oh; ++y)
            for (int z=0; z<ow; ++z) {
                int32_t acc=b[o];
                for (int c=0; c<channels; ++c)
                    for (int ky=0; ky<kh; ++ky)
                        for (int kx=0; kx<kw; ++kx) {
                            const int xi=(c*h+y+ky)*width+z+kx;
                            const int wi=((o*channels+c)*kh+ky)*kw+kx;
                            acc += (int32_t)x[xi] * (int32_t)w[wi];
                        }
                out[(o*oh+y)*ow+z]=acc;
            }
}

static void linear(const int8_t *x, const int8_t *w, const int32_t *b,
    int inputs, int outputs, int32_t *out)
{
    for (int o=0; o<outputs; ++o) {
        int32_t acc=b[o];
        for (int i=0; i<inputs; ++i)
            acc += (int32_t)x[i] * (int32_t)w[o*inputs+i];
        out[o]=acc;
    }
}

static int8_t requant(int32_t acc, int32_t multiplier, int shift)
{
    if (acc<=0) return 0;
    /* INT32_MAX squared + 2^29 fits INT64; acc is cast BEFORE multiply. */
    int64_t wide=(int64_t)acc * (int64_t)multiplier;
    if (shift>0) wide += INT64_C(1) << (shift-1);
    wide >>= shift;
    return (int8_t)(wide>127 ? 127 : wide);
}

static void activation(const int32_t *acc, int8_t *out, size_t count,
    int32_t multiplier, int shift)
{
    for (size_t i=0; i<count; ++i) out[i]=requant(acc[i],multiplier,shift);
}

static void pool(const int8_t *x, int channels, int h, int width, int8_t *out)
{
    for (int c=0; c<channels; ++c)
        for (int y=0; y<h/2; ++y)
            for (int z=0; z<width/2; ++z) {
                const int base=(c*h+2*y)*width+2*z;
                int8_t best=x[base];
                for (int ky=0; ky<2; ++ky)
                    for (int kx=0; kx<2; ++kx)
                        if (x[base+ky*width+kx]>best) best=x[base+ky*width+kx];
                out[(c*(h/2)+y)*(width/2)+z]=best;
            }
}

static int32_t argmax(const int32_t *x, size_t n)
{
    int32_t best=0;
    for (size_t i=1; i<n; ++i) if (x[i]>x[best]) best=(int32_t)i;
    return best;
}

size_t lenet_workspace_size(void) { return sizeof(lenet_workspace); }

int lenet_infer(const uint8_t *raw, size_t raw_len, lenet_workspace *s,
    size_t workspace_bytes, int32_t *logits, size_t logits_count, int32_t *class_id)
{
    if (!raw || !s || !logits || !class_id) return LENET_NULL;
    if (raw_len!=784 || workspace_bytes<sizeof(*s) || logits_count!=10) return LENET_SIZE;
    memset(s->input,0,sizeof(s->input));
    for (int y=0; y<28; ++y) memcpy(s->input+(y+2)*32+2,raw+y*28,28);
    conv(s->input,LENET_C1_WEIGHT,LENET_C1_BIAS,1,32,32,6,5,5,s->c1_acc);
    activation(s->c1_acc,s->c1_activation,4704,LENET_C1_MULTIPLIER,LENET_C1_SHIFT);
    pool(s->c1_activation,6,28,28,s->s2);
    conv((const uint8_t *)s->s2,LENET_C3_WEIGHT,LENET_C3_BIAS,6,14,14,16,5,5,s->c3_acc);
    activation(s->c3_acc,s->c3_activation,1600,LENET_C3_MULTIPLIER,LENET_C3_SHIFT);
    pool(s->c3_activation,16,10,10,s->s4);
    conv((const uint8_t *)s->s4,LENET_C5_WEIGHT,LENET_C5_BIAS,16,5,5,120,5,5,s->c5_acc);
    activation(s->c5_acc,s->c5_activation,120,LENET_C5_MULTIPLIER,LENET_C5_SHIFT);
    memcpy(s->flatten,s->c5_activation,sizeof(s->flatten));
    linear(s->flatten,LENET_F6_WEIGHT,LENET_F6_BIAS,120,84,s->f6_acc);
    activation(s->f6_acc,s->f6_activation,84,LENET_F6_MULTIPLIER,LENET_F6_SHIFT);
    linear(s->f6_activation,LENET_OUTPUT_WEIGHT,LENET_OUTPUT_BIAS,84,10,s->output_acc);
    s->predictions[0]=argmax(s->output_acc,10);
    memcpy(logits,s->output_acc,10*sizeof(*logits));
    *class_id=s->predictions[0];
    return LENET_OK;
}

const void *lenet_trace(const lenet_workspace *s, int id, size_t *count, int *dtype)
{
    if (!s || !count || !dtype) return NULL;
    *count=0; *dtype=0;
#define TRACE_CASE(ID,FIELD,TYPE) case ID: *count=sizeof(s->FIELD)/sizeof(s->FIELD[0]); *dtype=TYPE; return s->FIELD
    switch(id) {
    TRACE_CASE(0,input,LENET_U8);
    TRACE_CASE(1,c1_acc,LENET_I32);
    TRACE_CASE(2,c1_activation,LENET_I8);
    TRACE_CASE(3,s2,LENET_I8);
    TRACE_CASE(4,c3_acc,LENET_I32);
    TRACE_CASE(5,c3_activation,LENET_I8);
    TRACE_CASE(6,s4,LENET_I8);
    TRACE_CASE(7,c5_acc,LENET_I32);
    TRACE_CASE(8,c5_activation,LENET_I8);
    TRACE_CASE(9,flatten,LENET_I8);
    TRACE_CASE(10,f6_acc,LENET_I32);
    TRACE_CASE(11,f6_activation,LENET_I8);
    TRACE_CASE(12,output_acc,LENET_I32);
    TRACE_CASE(13,output_acc,LENET_I32); /* logits alias */
    TRACE_CASE(14,predictions,LENET_I32);
    default: return NULL;
    }
#undef TRACE_CASE
}

int lenet_debug_requant(int32_t acc, int32_t multiplier, int shift, int8_t *out)
{
    if (!out) return LENET_NULL;
    if (multiplier<1 || shift<0 || shift>30) return LENET_RANGE;
    *out=requant(acc,multiplier,shift); return LENET_OK;
}

int lenet_debug_argmax(const int32_t *x, size_t n, int32_t *out)
{
    if (!x || !out) return LENET_NULL;
    if (!n || n>INT32_MAX) return LENET_SIZE;
    *out=argmax(x,n); return LENET_OK;
}

int lenet_debug_pool(const int8_t *x, int channels, int h, int width, int8_t *out)
{
    if (!x || !out) return LENET_NULL;
    if (channels<1 || channels>120 || h<2 || h>32 || width<2 || width>32 || h%2 || width%2)
        return LENET_SIZE;
    for (int i=0; i<channels*h*width; ++i) if (x[i]<0) return LENET_RANGE;
    pool(x,channels,h,width,out); return LENET_OK;
}

int lenet_debug_conv(const uint8_t *x, const int8_t *w, const int32_t *b,
    int channels, int h, int width, int outputs, int kh, int kw, int32_t *out)
{
    if (!x || !w || !b || !out) return LENET_NULL;
    if (channels<1 || channels>120 || outputs<1 || outputs>120 || h<1 || h>32 ||
        width<1 || width>32 || kh<1 || kw<1 || kh>h || kw>width) return LENET_SIZE;
    const int length=channels*kh*kw;
    for (int o=0; o<outputs; ++o) {
        int64_t bound=b[o]<0 ? -(int64_t)b[o] : (int64_t)b[o];
        for (int i=0; i<length; ++i) {
            int32_t v=w[o*length+i];
            bound += INT64_C(255)*(v<0 ? -v : v);
        }
        if (bound>INT32_MAX) return LENET_RANGE;
    }
    conv(x,w,b,channels,h,width,outputs,kh,kw,out); return LENET_OK;
}
