/* main.c — Hệ thống hoàn chỉnh: camera -> 28x28 -> FC1 (MAC) -> ReLU (MCU) -> FC2 (MAC) -> argmax (MCU) -> HDMI
 *
 * Khởi động:
 *   Pha 0 : chép PARAM_INIT (W1, W2, B1, B2) từ flash MCU vào PARAM RAM của FPGA (offset 0x0800).
 *   Test  : - ReLU + requant chạy trên EXP_ACC1, so với EXP_HIDDEN (chỉ kiểm phần mềm).
 *           - FC2 riêng: ghi EXP_HIDDEN vào Hidden -> MAC chạy FC2 -> so Logit với EXP_LOGIT.
 *           - Với mỗi ảnh mẫu trong test_mlp.h (cả chuỗi):
 *             ghi ảnh vào IMAGE -> MAC chạy FC1 -> đọc Acc1[16], so với EXP_ACC1
 *             -> relu_requant(): Acc1 -> Hidden[16], đọc lại so với EXP_HIDDEN
 *             -> MAC chạy FC2 -> đọc Logit[10], so với EXP_LOGIT
 *             -> argmax(), so với EXP_CLASS.
 *           Kết quả ghi vào thanh ghi TEST, hiện ở hàng ô thứ 2 trên HDMI:
 *             ô 0 = Pha 0 xong, ô 1 = FC1 đúng hết các ảnh mẫu,
 *             ô 2 = ReLU + requant đúng (phần mềm), ô 3 = FC1 -> ReLU -> Hidden đúng (cả chuỗi),
 *             ô 4 = FC2 đúng (riêng), ô 5 = FC1 -> ReLU -> FC2 đúng (cả chuỗi),
 *             ô 6 = argmax ra đúng class, ô 7 = frame camera có chữ (đủ tương phản + đủ nét), đang nhận dạng (cập nhật mỗi frame).
 * Vòng lặp, mỗi frame:
 *   Pha 1 : camera -> band -> resize 28x28 xám -> IMAGE (0x0000): HDMI hiện đúng ảnh camera, không đảo màu, không giãn.
 *           Chuẩn hoá kiểu MNIST giống demo_image.py của nhóm training (mạng 784-16-10 không học dịch/co giãn):
 *           - Tự nhận chiều màu: nền là phần chiếm đa số, nét tối (giấy, iPad nền sáng) hay nét sáng (iPad chế độ tối).
 *           - Ngưỡng giữa nền và cực trị phía nét -> mask nét 28x28 (1 bit/pixel, mask[]).
 *           - Khung bao nét -> co giãn cạnh dài về 20 px (nội suy song tuyến) -> đặt trọng tâm vào (13.5, 13.5)
 *             trên nền đen 28x28 -> ghi vào NET (0x0400, chỉ bản sao MAC đọc, HDMI không thấy).
 *   Pha 2-5: FC1 -> ReLU + requant -> FC2 -> argmax.
 *   Hiển thị: kết quả phải giống nhau STABLE_N frame liên tiếp mới được ghi ra Digit:
 *            0..9 = số nhận được, 14 = 'E' (mạng không đủ tự tin: logit lớn nhất chỉ hơn logit
 *            thứ hai dưới MARGIN_MIN), 15 = gạch ngang (khung hình trống, tương phản thấp).
 *
 * Địa chỉ AHB (SRAM_FPGA_mapping.xlsx v2), base 0xA0000000:
 *   0x0000 IMAGE[196 word] | 0x0310 Acc1[16] | 0x0350 Hidden[4 word] | 0x0360 Logit[10] | 0x0388 Digit
 *   0x0400 NET[196 word] (chỉ ghi bản sao image mà MAC đọc)
 *   0x0800 PARAM (W1, W2, B1, B2) | 0x4000 BAND[112 word]
 *   0x4800 CTRL | 0x4804 STATUS | 0x4808 LED | 0x480C DBG | 0x4810 TEST
 */

#include "gw1ns4c.h"
#include <stdint.h>
#include <sys/stat.h>
#include "params.h"
#define ENABLE_SELFTEST 0
#if ENABLE_SELFTEST
#include "test_mlp.h"
#endif

#define BASE        0xA0000000UL
#define REG32(off)  (*(volatile uint32_t *)(BASE + (off)))

#define IMAGE(i)    REG32(0x0000 + (i) * 4)    /* ghi: HDMI + bản sao MAC; đọc: bản sao */
#define NET(i)      REG32(0x0400 + (i) * 4)    /* ghi: chỉ bản sao MAC (ảnh đã chuẩn hoá) */
#define ACC1(j)     (*(volatile int32_t *)(BASE + 0x0310 + (j) * 4))
#define HIDDEN(i)   REG32(0x0350 + (i) * 4)
#define LOGIT(k)    (*(volatile int32_t *)(BASE + 0x0360 + (k) * 4))
#define DIGIT       REG32(0x0388)
#define PARAM(i)    REG32(0x0800 + (i) * 4)
#define BAND(i)     REG32(0x4000 + (i) * 4)
#define CTRL        REG32(0x4800)
#define STATUS      REG32(0x4804)
#define LED         REG32(0x4808)
#define DBG         REG32(0x480C)
#define TEST        REG32(0x4810)

#define ST_DONE     0x02u       /* camera: band đầy                 */
#define ST_CFG      0x04u       /* camera: cấu hình SCCB xong       */
#define ST_MACBUSY  0x08u
#define ST_MACDONE  0x10u
#define CTRL_NEXT   0x01u
#define CTRL_FRAME  0x02u
#define CTRL_MAC    0x04u
#define CTRL_FC2    0x08u

#define T_PHA0      0x01u       /* ô 0 hàng 2 */
#define T_FC1       0x02u       /* ô 1 hàng 2 */
#define T_RELU_SW   0x04u       /* ô 2 hàng 2 */
#define T_RELU_HW   0x08u       /* ô 3 hàng 2 */
#define T_FC2       0x10u       /* ô 4 hàng 2 */
#define T_CHAIN2    0x20u       /* ô 5 hàng 2 */
#define T_CLASS     0x40u       /* ô 6 hàng 2 */
#define T_LIVE      0x80u       /* ô 7 hàng 2 */

#define DIGIT_ERR   14u         /* HDMI hiện 'E': mạng không đủ tự tin */
#define DIGIT_NONE  15u         /* HDMI hiện gạch ngang: khung hình trống */
#define MIN_CONTRAST 40u        /* |cực trị phía nét - trung bình| nhỏ hơn mức này -> coi là khung hình trống */
#define MIN_INK     6u          /* số pixel nét (trên 28x28) tối thiểu, ít hơn -> khung hình trống */
#define BOX         20          /* MNIST: cạnh dài của chữ số = 20 px trong khung 28x28 */
#define MARGIN_MIN  1500        /* logit lớn nhất - logit thứ hai; trên 100 ảnh mẫu giữ 90% ảnh đúng */
#define STABLE_N    3u          /* số frame liên tiếp cùng kết quả trước khi đổi số trên HDMI */
#define SHOW_NET    1           /* 1 = HDMI hiện ảnh đã chuẩn hoá kiểu MNIST (nền đen, chữ trắng, 20px trọng tâm) */

#define N_OUT       28
#define N_BAND      28

volatile uint32_t frame_count;      /* xem bằng debugger */
volatile uint32_t cam_dbg;
#if ENABLE_SELFTEST
volatile uint32_t fc1_err;          /* số giá trị Acc1 sai trên tất cả ảnh mẫu */
volatile int32_t  acc1_got[16];     /* Acc1 của ảnh mẫu cuối cùng */
volatile uint32_t relu_sw_err;      /* số giá trị Hidden sai khi tính từ EXP_ACC1 */
volatile uint32_t relu_hw_err;      /* số giá trị Hidden sai khi tính từ Acc1 của MAC (đọc lại từ FPGA) */
volatile int8_t   hidden_got[16];   /* Hidden đọc lại của ảnh mẫu cuối cùng */
volatile uint32_t fc2_err;          /* số giá trị Logit sai khi FC2 chạy riêng trên EXP_HIDDEN */
volatile uint32_t chain2_err;       /* số giá trị Logit sai khi chạy cả chuỗi FC1 -> ReLU -> FC2 */
volatile uint32_t class_err;        /* số ảnh mẫu argmax ra sai class */
#endif
volatile int32_t  logit_got[10];    /* Logit của lần FC2 cuối cùng */
volatile uint32_t digit_now;        /* kết quả frame gần nhất trước khi lọc (0..9, 14 = E, 15 = trống) */
volatile int32_t  margin_now;       /* logit lớn nhất - logit thứ hai của lần argmax gần nhất */
volatile uint32_t img_mean, img_span; /* mức nền và độ tương phản phía nét của frame gần nhất */
volatile uint32_t img_inv;          /* 1 = nét tối trên nền sáng, 0 = nét sáng trên nền tối */
volatile uint32_t ink_count;        /* số pixel nét trong mask 28x28 của frame gần nhất */
volatile uint32_t box_w, box_h;     /* khung bao nét (pixel 28x28) của frame gần nhất */
volatile uint32_t infer_err;        /* số lần MAC quá thời gian khi nhận dạng realtime */

/* Tiền xử lý ảnh */
static uint32_t nrm_inv = 1;        /* 1 = nét tối trên nền sáng (mặc định), có trễ khi đổi chiều */
static uint32_t st_sum, st_max, st_min = 255;   /* thống kê xám thô của frame đang chụp */
static uint32_t mask[N_BAND];       /* mask nét: bit x của mask[y] = 1 nếu pixel (x, y) là nét */
static int32_t  nx0, ny0, nstep;    /* góc khung bao + bước lấy mẫu (Q8) dùng cho sample() */

/* ---------------- Pha 0: nạp hệ số vào PARAM RAM ---------------- */
static void load_params(void)
{
    int i;
    for (i = 0; i < PARAM_WORDS; i++)
        PARAM(i) = PARAM_INIT[i];
}

/* ---------------- Gọi khối MAC, trả 0 nếu xong, -1 nếu quá thời gian ---------------- */
static int mac_run(uint32_t layer)
{
    uint32_t t = 0;
    CTRL = CTRL_MAC | layer;
    while ((STATUS & ST_MACDONE) == 0) {
        if (++t > 2000000u) return -1;
    }
    return 0;
}

/* ---------------- Pha 3: ReLU + requant 1 giá trị (giống inference.c.ref) ----------------
 * acc <= 0 -> 0. Ngược lại hidden = round(acc * FC1_MULT / 2^FC1_SHIFT), chặn trên 127. */
static int8_t relu_q(int32_t acc)
{
    int64_t wide;
    if (acc <= 0)
        return 0;
    wide  = (int64_t)acc * FC1_MULT;            /* ép kiểu trước khi nhân */
    wide += (int64_t)1 << (FC1_SHIFT - 1);      /* làm tròn */
    wide >>= FC1_SHIFT;                         /* chỉ dịch số không âm */
    if (wide > 127)
        wide = 127;
    return (int8_t)wide;
}

/* ---------------- Pha 3: đọc Acc1[16] -> Hidden[16], ghi vào thanh ghi Hidden ----------------
 * Mỗi word chứa 4 giá trị: Hidden[j] ở byte (j & 3) của word (j >> 2), đúng thứ tự khối MAC đọc. */
static void relu_requant(void)
{
    int j;
    uint32_t packed = 0;
    for (j = 0; j < 16; j++) {
        packed |= (uint32_t)(uint8_t)relu_q(ACC1(j)) << (8 * (j & 3));
        if ((j & 3) == 3) {
            HIDDEN(j >> 2) = packed;
            packed = 0;
        }
    }
}

#if ENABLE_SELFTEST
/* ---------------- Tự kiểm tra ReLU + requant chỉ bằng phần mềm ---------------- */
static int test_relu_sw(void)
{
    int n, j;
    relu_sw_err = 0;
    for (n = 0; n < N_TEST; n++)
        for (j = 0; j < 16; j++)
            if (relu_q(EXP_ACC1[n][j]) != EXP_HIDDEN[n][j])
                relu_sw_err++;
    return relu_sw_err == 0;
}
#endif

/* ---------------- Pha 4: FC2 trên khối MAC (đọc Hidden, W2, B2) -> Logit[10] ---------------- */
static int run_fc2(void)
{
    return mac_run(CTRL_FC2);
}

/* ---------------- Pha 5: argmax trên Logit[10], trả vị trí lớn nhất đầu tiên (giống inference.c.ref) ----------------
 * Đồng thời tính margin_now = logit lớn nhất - logit lớn thứ hai (độ tự tin của mạng). */
static uint32_t argmax(void)
{
    uint32_t k, best = 0;
    int32_t  v, bv = LOGIT(0), sv = INT32_MIN;
    logit_got[0] = bv;
    for (k = 1; k < 10; k++) {
        v = LOGIT(k);
        logit_got[k] = v;
        if (v > bv) {
            sv = bv;
            bv = v;
            best = k;
        } else if (v > sv) {
            sv = v;
        }
    }
    margin_now = bv - sv;
    return best;
}

#if ENABLE_SELFTEST
/* Đọc Logit[10], trả số giá trị khác với exp (16 nếu MAC quá thời gian) */
static uint32_t check_logit(int ok, const int32_t exp[10])
{
    int k;
    uint32_t e = 0;
    if (!ok)
        return 16;
    for (k = 0; k < 10; k++) {
        logit_got[k] = LOGIT(k);
        if (logit_got[k] != exp[k])
            e++;
    }
    return e;
}

/* ---------------- Tự kiểm tra FC2 riêng: Hidden lấy đúng từ EXP_HIDDEN ---------------- */
static int test_fc2(void)
{
    int n, w;
    fc2_err = 0;
    for (n = 0; n < N_TEST; n++) {
        for (w = 0; w < 4; w++)
            HIDDEN(w) =  (uint32_t)(uint8_t)EXP_HIDDEN[n][4 * w]
                      | ((uint32_t)(uint8_t)EXP_HIDDEN[n][4 * w + 1] << 8)
                      | ((uint32_t)(uint8_t)EXP_HIDDEN[n][4 * w + 2] << 16)
                      | ((uint32_t)(uint8_t)EXP_HIDDEN[n][4 * w + 3] << 24);
        fc2_err += check_logit(run_fc2() == 0, EXP_LOGIT[n]);
    }
    return fc2_err == 0;
}

/* ---------------- Tự kiểm tra cả chuỗi FC1 (MAC) -> ReLU (MCU) -> FC2 (MAC) -> argmax (MCU) với ảnh mẫu ----------------
 * Trả về các bit T_FC1 / T_RELU_HW / T_CHAIN2 / T_CLASS đạt được. */
static uint32_t test_chain(void)
{
    int n, i, j, ok2;
    fc1_err = 0;
    relu_hw_err = 0;
    chain2_err = 0;
    class_err = 0;
    for (n = 0; n < N_TEST; n++) {
        for (i = 0; i < 196; i++)
            IMAGE(i) = TEST_IMG[n][i];
        if (mac_run(0) != 0) {
            fc1_err += 16;
            relu_hw_err += 16;
            chain2_err += 16;
            class_err++;
            continue;
        }
        for (j = 0; j < 16; j++) {
            acc1_got[j] = ACC1(j);
            if (acc1_got[j] != EXP_ACC1[n][j])
                fc1_err++;
        }

        relu_requant();
        for (j = 0; j < 16; j++) {
            hidden_got[j] = (int8_t)(HIDDEN(j >> 2) >> (8 * (j & 3)));
            if (hidden_got[j] != EXP_HIDDEN[n][j])
                relu_hw_err++;
        }

        ok2 = (run_fc2() == 0);
        chain2_err += check_logit(ok2, EXP_LOGIT[n]);
        if (!ok2 || argmax() != EXP_CLASS[n])
            class_err++;
    }
    return (fc1_err     == 0 ? T_FC1     : 0u)
         | (relu_hw_err == 0 ? T_RELU_HW : 0u)
         | (chain2_err  == 0 ? T_CHAIN2  : 0u)
         | (class_err   == 0 ? T_CLASS   : 0u);
}
#endif

/* ---------------- Nhận dạng ảnh đang nằm trong IMAGE: trả 0..9, hoặc DIGIT_NONE nếu MAC quá thời gian ---------------- */
static uint32_t infer(void)
{
    if (mac_run(0) != 0)            /* Pha 2: FC1  */
        return DIGIT_NONE;
    relu_requant();                 /* Pha 3: ReLU */
    if (run_fc2() != 0)             /* Pha 4: FC2  */
        return DIGIT_NONE;
    return argmax();                /* Pha 5       */
}

/* ---------------- Pha 1: resize 1 band (4 hàng x 112) -> 1 hàng 28 pixel xám ----------------
 * Trung bình 4x4 pixel -> g, ghi nguyên g vào IMAGE (HDMI hiện ảnh camera thật, bản sao dùng để làm mask),
 * đồng thời cộng dồn thống kê xám của frame này. */
static void resize_band(int b)
{
    int c, r;
    uint32_t packed = 0;

    for (c = 0; c < N_OUT; c++) {
        uint32_t sum = 0, g;
        for (r = 0; r < 4; r++) {
            uint32_t w = BAND(r * N_OUT + c);
            sum += (w & 0xFF) + ((w >> 8) & 0xFF) + ((w >> 16) & 0xFF) + ((w >> 24) & 0xFF);
        }
        g = sum >> 4;
        st_sum += g;
        if (g > st_max) st_max = g;
        if (g < st_min) st_min = g;

        packed |= g << (8 * (c & 3));
        if ((c & 3) == 3) {
#if SHOW_NET
            NET(b * (N_OUT / 4) + (c >> 2)) = packed;
#else
            IMAGE(b * (N_OUT / 4) + (c >> 2)) = packed;
#endif
            packed = 0;
        }
    }
}

/* Chiều màu + độ tương phản của frame vừa chụp. Trả 1 nếu đủ tương phản.
 * Nền chiếm phần lớn ảnh nên trung bình gần mức nền; nét viết nằm về phía cực trị xa trung bình hơn:
 *   up   = max - mean (phía sáng),  down = mean - min (phía tối)
 *   down > up -> nét tối;  up > down -> nét sáng.
 * Chỉ đổi chiều khi phía kia lớn hơn rõ ràng (hơn 25%) để không lật qua lật lại. */
static int frame_stats(void)
{
    uint32_t mean = st_sum / (N_OUT * N_BAND);
    uint32_t up   = st_max - mean;
    uint32_t down = mean - st_min;

    if (nrm_inv) {
        if (up * 4u > down * 5u) nrm_inv = 0;
    } else {
        if (down * 4u > up * 5u) nrm_inv = 1;
    }
    img_mean = mean;
    img_span = nrm_inv ? down : up;
    img_inv  = nrm_inv;

    st_sum = 0;
    st_max = 0;
    st_min = 255u;
    return img_span >= MIN_CONTRAST;
}

/* Đọc lại ảnh xám (bản sao trong FPGA) -> mask nét với ngưỡng nằm giữa nền và cực trị phía nét.
 * Word i chứa hàng y = i / 7, cột x = (i % 7) * 4 + j ở byte j. Trả số pixel nét. */
static uint32_t build_mask(void)
{
    int i, j;
    uint32_t n = 0;
    uint32_t half = img_span / 2u;
    uint32_t thr  = nrm_inv ? img_mean - half : img_mean + half;

    for (i = 0; i < N_BAND; i++)
        mask[i] = 0;
    for (i = 0; i < N_BAND * (N_OUT / 4); i++) {
        uint32_t w = IMAGE(i);
        for (j = 0; j < 4; j++) {
            uint32_t g = (w >> (8 * j)) & 0xFF;
            if (nrm_inv ? (g < thr) : (g > thr)) {
                mask[i / 7] |= 1u << ((i % 7) * 4 + j);
                n++;
            }
        }
    }
    return n;
}

/* Pixel (x, y) của mask: 255 nếu là nét, 0 nếu là nền hoặc nằm ngoài ảnh */
static int32_t mask_px(int32_t x, int32_t y)
{
    if (x < 0 || x >= N_OUT || y < 0 || y >= N_BAND)
        return 0;
    return ((mask[y] >> x) & 1u) ? 255 : 0;
}

/* Pixel (u, v) của chữ số sau co giãn: nội suy song tuyến trên mask, toạ độ tâm pixel, số Q8.
 * Pixel đích u ứng với toạ độ nguồn x0 + (u + 0.5) * step - 0.5. (dịch phải số âm = floor với gcc) */
static uint32_t sample(int32_t u, int32_t v)
{
    int32_t sx  = (nx0 << 8) + (((2 * u + 1) * nstep) >> 1) - 128;
    int32_t sy  = (ny0 << 8) + (((2 * v + 1) * nstep) >> 1) - 128;
    int32_t ix  = sx >> 8, fx = sx & 255;
    int32_t iy  = sy >> 8, fy = sy & 255;
    int32_t top = mask_px(ix, iy)     * (256 - fx) + mask_px(ix + 1, iy)     * fx;
    int32_t bot = mask_px(ix, iy + 1) * (256 - fx) + mask_px(ix + 1, iy + 1) * fx;
    return (uint32_t)((top * (256 - fy) + bot * fy) >> 16);
}

/* Chuẩn hoá kiểu MNIST từ mask -> NET (ảnh đầu vào MAC), giống demo_image.py:
 *   khung bao nét -> cạnh dài về BOX = 20 px, giữ tỉ lệ -> trọng tâm về (13.5, 13.5), nền 0.
 * Trả 0 nếu không có nét. */
static int normalize(void)
{
    int32_t x, y, u, v, i, j;
    int32_t x0 = N_OUT, x1 = -1, y0 = N_BAND, y1 = -1;
    int32_t w, h, s, ow, oh, left, top;
    uint32_t d, tot = 0, sum_xd = 0, sum_yd = 0, cx2, cy2;

    for (y = 0; y < N_BAND; y++) {
        if (mask[y] == 0)
            continue;
        if (y < y0) y0 = y;
        y1 = y;
        for (x = 0; x < N_OUT; x++)
            if ((mask[y] >> x) & 1u) {
                if (x < x0) x0 = x;
                if (x > x1) x1 = x;
            }
    }
    if (x1 < 0)
        return 0;
    w = x1 - x0 + 1;
    h = y1 - y0 + 1;
    s = (w > h) ? w : h;
    ow = (w * BOX + s / 2) / s;  if (ow < 1) ow = 1;
    oh = (h * BOX + s / 2) / s;  if (oh < 1) oh = 1;
    nx0 = x0;
    ny0 = y0;
    nstep = (s << 8) / BOX;
    box_w = (uint32_t)w;
    box_h = (uint32_t)h;

    /* Lần 1: trọng tâm của chữ số đã co giãn (không cần bộ đệm) */
    for (v = 0; v < oh; v++)
        for (u = 0; u < ow; u++) {
            d = sample(u, v);
            tot    += d;
            sum_xd += (uint32_t)u * d;
            sum_yd += (uint32_t)v * d;
        }
    if (tot == 0)
        return 0;
    cx2 = (2u * sum_xd + tot) / tot;                    /* 2 * cx + 1, làm tròn */
    cy2 = (2u * sum_yd + tot) / tot;
    left = (cx2 <= 27u) ? (int32_t)(28u - cx2) / 2 : 0; /* round(13.5 - cx) */
    top  = (cy2 <= 27u) ? (int32_t)(28u - cy2) / 2 : 0;
    if (left > N_OUT - ow)  left = N_OUT - ow;
    if (top  > N_BAND - oh) top  = N_BAND - oh;

    /* Lần 2: ghi 28x28 vào NET, 4 pixel / word giống IMAGE */
    for (i = 0; i < N_BAND * (N_OUT / 4); i++) {
        uint32_t packed = 0;
        y = i / 7;
        v = y - top;
        for (j = 0; j < 4; j++) {
            u = (i % 7) * 4 + j - left;
            if (u >= 0 && u < ow && v >= 0 && v < oh)
                packed |= sample(u, v) << (8 * j);
        }
#if SHOW_NET
        IMAGE(i) = packed;                  /* ghi cả HDMI + bản sao MAC: thấy đúng ảnh mạng nhận */
#else
        NET(i) = packed;
#endif
    }
    return 1;
}

int main(void)
{
    int b, k;
    uint32_t test = 0;
    uint32_t cand_prev = DIGIT_NONE, cand_cnt = 0;

    SystemInit();

    /* Pha 0: Nạp trọng số từ Flash MCU vào PARAM RAM */
    load_params();
    test |= T_PHA0;
    TEST = test;

#if ENABLE_SELFTEST
    /* Tự kiểm tra: ReLU (phần mềm) -> FC2 riêng -> cả chuỗi FC1 -> ReLU -> FC2 -> argmax */
    if (test_relu_sw())
        test |= T_RELU_SW;
    TEST = test;
    if (test_fc2())
        test |= T_FC2;
    TEST = test;
    test |= test_chain();
    TEST = test;
#endif

    /* Bỏ qua self-test theo yêu cầu: vào thẳng camera realtime */
    DIGIT = DIGIT_NONE;

    /* Pha 1: camera */
    while ((STATUS & ST_CFG) == 0);

    while (1) {
        int valid;

        CTRL = CTRL_FRAME;
        for (b = 0; b < N_BAND; b++) {
            while ((STATUS & ST_DONE) == 0);
            resize_band(b);
            if (b < N_BAND - 1)
                CTRL = CTRL_NEXT;
        }

        /* Frame hợp lệ: đủ tương phản, đủ nét, chuẩn hoá được -> NET */
        valid = frame_stats();
        ink_count = valid ? build_mask() : 0u;
        valid = valid && (ink_count >= MIN_INK) && normalize();
        if (!valid) {
            digit_now = DIGIT_NONE;                 /* khung hình trống -> gạch ngang */
#if SHOW_NET
            for (k = 0; k < N_BAND * (N_OUT / 4); k++)
                IMAGE(k) = 0;                       /* khung hình trống: màn hình MNIST nền đen hoàn toàn */
#endif
        } else {
            digit_now = infer();                    /* Pha 2-5 */
            if (digit_now == DIGIT_NONE) {          /* MAC quá thời gian */
                infer_err++;
                digit_now = DIGIT_ERR;
            } else if (margin_now < MARGIN_MIN) {   /* không số nào vượt hẳn -> 'E' */
                digit_now = DIGIT_ERR;
            }
        }

        /* Lọc ổn định: chỉ đổi ký tự trên HDMI khi cùng kết quả lặp lại STABLE_N frame liên tiếp */
        if (digit_now == cand_prev) {
            if (cand_cnt < STABLE_N)
                cand_cnt++;
        } else {
            cand_prev = digit_now;
            cand_cnt  = 1;
        }
        if (cand_cnt >= STABLE_N)
            DIGIT = cand_prev;
        TEST = valid ? (test | T_LIVE) : (test & ~T_LIVE);

        frame_count++;
        cam_dbg = DBG;
    }
}

/* Hàm hệ thống rỗng: newlib yêu cầu khi link, chương trình này không dùng printf/file */
int _write(int f, char *p, int l)   { (void)f; (void)p; return l; }
int _read(int f, char *p, int l)    { (void)f; (void)p; (void)l; return 0; }
int _lseek(int f, int p, int d)     { (void)f; (void)p; (void)d; return 0; }
int _close(int f)                   { (void)f; return -1; }
int _fstat(int f, struct stat *s)   { (void)f; s->st_mode = S_IFCHR; return 0; }
int _isatty(int f)                  { (void)f; return 1; }
int _getpid(void)                   { return 1; }
int _kill(int p, int s)             { (void)p; (void)s; return -1; }
