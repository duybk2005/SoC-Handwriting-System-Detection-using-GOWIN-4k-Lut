# 16-Lane GEMM Core (SystemVerilog) cho CNN LeNet-5 trên Tang Nano 4K

Lõi nhân ma trận tổng quát (GEMM - General Matrix Multiplication) 16 lane, kiến trúc **Output-Stationary**, viết bằng SystemVerilog-2012 synthesizable. Mục tiêu: board **Sipeed Tang Nano 4K** (Gowin **GW1NSR-LV4C**), xung nhịp **50 MHz**.

Lõi tính một block của phép toán:

```
A[M×N] = W[M×K] · P[K×N] + B[M] · 1ᵀ[N]
```

Mỗi lần chạy, lõi tính **16 phần tử đầu ra song song** (16 pixel của một hàng) trong **K chu kỳ**:

```
acc[j] = bias[j] + Σ (i = 0..K-1)  w[i] · p[i][j]        với j = 0..15
```

- `w[i]` (INT8): trọng số, **broadcast** chung cho cả 16 lane ở chu kỳ thứ `i`.
- `p[i][j]` (INT8): pixel/phần tử của lane `j` ở chu kỳ thứ `i`.
- `bias[j]` (INT32): giá trị khởi tạo của accumulator.
- `acc[j]` (INT32): kết quả, nằm yên trong thanh ghi tới khi xong (output-stationary).

---

## 1. Cấu trúc thư mục

| File | Vai trò |
|---|---|
| `gemm_array.sv` | Datapath: 16 PE (nhân INT8×INT8 + cộng dồn INT32) |
| `gemm_controller.sv` | FSM điều khiển: tạo `clear`, `load_bias`, `enable`, `tick` |
| `gemm_top.sv` | Top-level nối controller và array |
| `tb_gemm_top.sv` | Testbench tự kiểm tra (self-checking) |

---

## 2. Sơ đồ khối

```
                  ┌───────────────────────────────────────────────┐
 bias_in[16] ───► │                                               │
 (INT32)          │                gemm_array                     │
 broadcast_in ──► │   16 PE:  acc[j] += broadcast_in*element_in[j]│──► result_out[16]
 (INT8)           │                                               │    (INT32)
 element_in[16]─► │                                               │
 (INT8)           └───▲───────▲───────────▲──────────▲────────────┘
                      │clear  │load_bias  │enable    │
                  ┌───┴───────┴───────────┴──────────┴────┐
 start ─────────► │             gemm_controller           │──► tick
 k_length[15:0] ─►│   FSM + bộ đếm K                      │──► busy
                  └───────────────────────────────────────┘
```

Trong hệ thống đầy đủ, `gemm_top` được ghép với: bias buffer (16×INT32), bộ nhớ trọng số/broadcast (INT8), Ping-pong buffer (K×16 INT8), DMA và Out_buffer. Tín hiệu `clear`, `load_bias`, `enable`, `tick` được đưa ra ngoài để các khối này đồng bộ với lõi.

---

## 3. Giao diện (ports)

### `gemm_top`

| Port | Hướng | Rộng | Mô tả |
|---|---|---|---|
| `clk` | in | 1 | Xung nhịp hệ thống (50 MHz) |
| `rst_n` | in | 1 | Reset bất đồng bộ, tích cực mức thấp |
| `start` | in | 1 | Xung bắt đầu một block (nên giữ 1 chu kỳ). Bị bỏ qua nếu `busy=1` |
| `k_length` | in | 16 | Số vòng lặp K. Được chốt tại thời điểm `start` |
| `bias_in[0:15]` | in | 16×signed 32 | Bias ban đầu; phải ổn định tại chu kỳ `load_bias` |
| `broadcast_in` | in | signed 8 | Trọng số `w[i]`, hợp lệ trong chu kỳ `enable=1` |
| `element_in[0:15]` | in | 16×signed 8 | Phần tử `p[i][0..15]`, hợp lệ trong chu kỳ `enable=1` |
| `result_out[0:15]` | out | 16×signed 32 | 16 accumulator. **Hợp lệ khi `tick=1`** |
| `tick` | out | 1 | Xung 1 chu kỳ báo hoàn tất block |
| `clear` | out | 1 | Đang xóa accumulator (có thể dùng để đồng bộ khối ngoài) |
| `load_bias` | out | 1 | Đang nạp bias |
| `enable` | out | 1 | Đang tích lũy; dữ liệu cần có mặt trong chu kỳ này |
| `busy` | out | 1 | `1` từ lúc nhận `start` đến hết chu kỳ `tick` |

### Tham số

| Tham số | Mặc định | Ý nghĩa |
|---|---|---|
| `LANES` | 16 | Số lane song song |
| `PIPELINE` | 1 | `1`: thêm 1 tầng thanh ghi sau bộ nhân (dễ map vào DSP, thêm 1 chu kỳ latency). `0`: nhân và cộng trong cùng chu kỳ |

`gemm_controller` có tham số `ACC_LATENCY` (0 hoặc 1); `gemm_top` tự đặt giá trị này theo `PIPELINE`.

---

## 4. Giải thích từng module

### 4.1. `gemm_array.sv` - Datapath

Mỗi lane `j` thực hiện hai bước:

1. **Nhân có dấu:** `prod = broadcast_in * element_in[j]`, INT8 × INT8 → INT16. Trường hợp xấu nhất `(-128)×(-128) = 16384` vẫn nằm trong INT16.
2. **Cộng dồn** vào accumulator 32-bit, theo thứ tự ưu tiên:

```systemverilog
if      (clear)      acc <= 32'sd0;        // ưu tiên cao nhất
else if (load_bias)  acc <= bias_in[j];    // nạp bias
else if (acc_en)     acc <= acc + 32'(prod_s); // cộng dồn (sign-extend 16→32)
```

**Về `PIPELINE`:**

- `PIPELINE=1`: tích `prod_c` được đăng ký thành `prod_q`, đồng thời `enable` được trễ 1 chu kỳ thành `en_q` để hai tín hiệu luôn thẳng hàng. Cấu trúc "nhân → thanh ghi → cộng" giúp công cụ tổng hợp dễ đặt bộ nhân vào khối DSP/MULT của Gowin.
- `PIPELINE=0`: tích đi thẳng vào bộ cộng, không có tầng đệm.

`prod_q` không có reset vì chỉ được dùng khi `en_q=1` (`en_q` có reset).

### 4.2. `gemm_controller.sv` - FSM

```
IDLE ─start→ CLEAR → BIAS → RUN (K chu kỳ) → DRAIN → TICK → IDLE
              clear   load_bias  enable      (ACC_LATENCY chu kỳ)   tick
```

| State | Số chu kỳ | Đầu ra | Việc làm |
|---|---|---|---|
| `IDLE` | - | - | Chờ `start`; chốt `k_length` vào `k_reg` |
| `CLEAR` | 1 | `clear=1` | Xóa 16 accumulator |
| `BIAS` | 1 | `load_bias=1` | Nạp bias vào accumulator (chu kỳ 0) |
| `RUN` | K | `enable=1` | Tích lũy K chu kỳ |
| `DRAIN` | `ACC_LATENCY` | - | Chờ dữ liệu cuối đi qua tầng pipeline |
| `TICK` | 1 | `tick=1` | Xung hoàn tất; `result_out` đã là kết quả cuối |

Điểm cần chú ý:

- Đầu ra kiểu **Moore** (giải mã trực tiếp từ state).
- `K = 0` được xử lý đúng: bỏ qua `RUN`, kết quả bằng bias.
- `start` trong lúc `busy=1` bị bỏ qua.

### 4.3. `gemm_top.sv`

Chỉ ghép nối `gemm_controller` và `gemm_array`, đồng thời đưa các tín hiệu điều khiển ra ngoài để khối buffer/DMA dùng.

---

## 5. Giản đồ thời gian (K = 5, `PIPELINE=1`)

```
chu kỳ     : 1    2     3     4   5   6   7   8     9      10
state      : IDLE CLEAR BIAS  RUN RUN RUN RUN RUN   DRAIN  TICK
start      : _/‾‾‾\______________________________________________
clear      :      ‾‾‾‾‾\_________________________________________
load_bias  :            ‾‾‾‾‾\___________________________________
enable     :                  ‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾‾\_______________
data (w,p) :                  w0  w1  w2  w3  w4   (không cần)
tick       : _________________________________________ ‾‾‾‾‾\____
result_out : ...............................................valid
```

Công thức: `tick` xuất hiện ở chu kỳ thứ **`K + 4 + ACC_LATENCY`** tính từ chu kỳ lấy mẫu `start` (ở đây `5 + 4 + 1 = 10`).

---

## 6. Cách dùng

1. Chuẩn bị `bias_in` (ổn định tới hết chu kỳ `load_bias`) và `k_length`.
2. Phát xung `start` 1 chu kỳ.
3. Quan sát `enable`: trong **đúng K chu kỳ** `enable=1`, đưa `broadcast_in = w[i]` và `element_in[j] = p[i][j]` cho `i = 0..K-1`.
4. Khi `tick=1`, đọc `result_out[0:15]` (lưu vào Out_buffer).
5. Với ma trận có `N` lớn hơn 16, lặp lại cho từng block 16 cột (`⌈N/16⌉` block), mỗi block là một lần `start`.

> **Lưu ý khi dùng BSRAM của Gowin làm Ping-pong buffer:** BSRAM đọc đồng bộ, trễ 1 chu kỳ. Dữ liệu phải có mặt đúng trong chu kỳ `enable=1`, nên địa chỉ cần được phát sớm hơn 1 chu kỳ so với `enable` (ví dụ thêm state `PREFETCH` trước `RUN`).


