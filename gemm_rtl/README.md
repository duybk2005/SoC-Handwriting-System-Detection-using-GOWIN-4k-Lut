# GEMM Array – 16-lane Output-Stationary MAC cho LeNet-5 (Gowin Tang Nano 4K)

Module Verilog-2001 tổng hợp được (synthesizable) thực hiện **một block nhân ma trận 1×16** theo kiểu **output-stationary**, dùng làm lõi tính toán trong bộ tăng tốc LeNet-5 trên FPGA **Gowin GW1NSR-LV4CQN48PC7I6** (Tang Nano 4K).

## 1. Ý tưởng

Phép nhân ma trận tổng quát (GEMM) của một layer:

```
A[M×N] = W[M×K] · P[K×N] + B[M] · 1ᵀ[N]
```

Ma trận đầu ra được chia thành các **block rộng 16 pixel**. Với mỗi block, module chạy **K chu kỳ**:

- `broadcast_in` (INT8): một trọng số `w[0,i]`, **phát chung cho cả 16 lane**, giữ cố định trong 1 chu kỳ.
- `element_in` (16 × INT8): 16 phần tử kích hoạt `p[i,0..15]`, đưa vào đồng thời mỗi chu kỳ.
- Mỗi lane có **một bộ cộng dồn INT32 riêng** (kết quả "đứng yên" trong lane → *output-stationary*), khởi tạo bằng giá trị bias.

```
acc[j] <= acc[j] + broadcast_in * element_in[j]      (j = 0..15, lặp K lần)
```

Sau K chu kỳ, `acc[0..15]` chính là 16 kết quả đầu ra INT32 của block.

## 2. Sơ đồ khối

```
               bias_in[511:0] (16 x INT32)
                      │
 broadcast_in[7:0] ───┼──────────────┐
                      ▼              ▼
 element_in[127:0] ► ┌─────────────────────────┐
  (16 x INT8)        │  16 x MAC lane          │──► result_out[511:0]
 clear ─────────────►│  acc[j] += w * p[j]     │     (16 x INT32)
 k_length[15:0] ────►│  + bộ đếm k_cnt         │──► tick
 clk, rst_n ────────►└─────────────────────────┘
```

## 3. Giao diện (ports)

| Tín hiệu | Hướng | Độ rộng | Mô tả |
|---|---|---|---|
| `clk` | in | 1 | Clock hệ thống (thường 50 MHz) |
| `rst_n` | in | 1 | Reset mức thấp. Assert bất đồng bộ, nhả đồng bộ với clk |
| `clear` | in | 1 | Từ Controller. Khi = 1: nạp lại bias vào accumulator, đưa `k_cnt` về 0, bắt đầu block mới |
| `k_length` | in | 16 | Số chu kỳ cộng dồn K của mỗi block (vd. 25 cho conv1) |
| `bias_in` | in | 512 | 16 bias INT32, lane *j* = `bias_in[32*j +: 32]` |
| `broadcast_in` | in | 8 | Trọng số INT8 có dấu, dùng chung cho 16 lane |
| `element_in` | in | 128 | 16 phần tử INT8 có dấu, lane *j* = `element_in[8*j +: 8]` |
| `tick` | out | 1 | Xung 1 chu kỳ khi đã đủ K chu kỳ cộng dồn |
| `result_out` | out | 512 | 16 kết quả INT32, lane *j* = `result_out[32*j +: 32]` |

> **Vì sao `k_length` là cổng (port) chứ không phải parameter?**
> K thay đổi theo từng layer của LeNet-5 (conv1: 25, conv2: 150, fc1: 400, …), nên để cấu hình lúc chạy sẽ linh hoạt hơn. Nếu muốn cố định, nối cứng `k_length` với `16'd25`.

## 4. Giao thức / Timing

| Chu kỳ | `clear` | Dữ liệu trên bus | Việc xảy ra ở cạnh lên clk kế tiếp |
|---|---|---|---|
| 0 | **1** | (không quan trọng) | `acc <= bias`, `k_cnt <= 0` |
| 1 | 0 | cặp `k = 0` | `acc += w·p` |
| 2 | 0 | cặp `k = 1` | `acc += w·p` |
| … | 0 | … | … |
| K | 0 | cặp `k = K-1` | `acc += w·p` **và** `tick <= 1` |
| K+1 | 0 | bất kỳ | `tick <= 0`, `acc` được **giữ nguyên** |

Điểm cần lưu ý:

1. `bias_in` và `k_length` phải hợp lệ tại thời điểm `clear = 1`.
2. Cặp (trọng số, phần tử) đầu tiên phải có mặt trên bus **ngay chu kỳ đầu tiên sau khi `clear` hạ xuống**. Mỗi chu kỳ sau đó là một cặp mới, tổng cộng K cặp. Controller / ping-pong buffer cần canh đúng nhịp này.
3. `tick` là thanh ghi, lên **cùng cạnh clock** với lần cộng dồn cuối. Nghĩa là khi `tick = 1` thì `result_out` đã là giá trị cuối cùng, Controller có thể phát `save` / `address` sang `Out_buffer` luôn.
4. Sau `tick`, mảng ngừng cộng dồn và giữ `result_out` cho đến lần `clear` tiếp theo.
5. Nếu `k_length = 0` thì được coi như `k_length = 1`.

## 5. Chi tiết cài đặt

- **Nhân có dấu:** `wire signed [15:0] prod = w_s * elem_s;` (INT8 × INT8 → INT16, tối đa +16384 khi (-128)·(-128), vừa đủ trong 16 bit có dấu).
- **Mở rộng dấu:** `acc` và `prod` đều khai báo `signed` nên phép `acc + prod` tự động sign-extend `prod` lên 32 bit.
- **Độ rộng accumulator:** INT32 đủ cho K lớn (mỗi tích tối đa 2¹⁴, K đến vài chục nghìn vẫn không tràn nếu bias không quá lớn).
- **16 lane** được tạo bằng `generate for`, mỗi lane gồm: bộ nhân + thanh ghi `acc` + gán `result_out`.
- **Bộ điều khiển** gồm `k_cnt` (đếm 0 → K-1), cờ `running` (đang tính) và `tick`.
- Bộ nhân 8×8 nhiều khả năng được ánh xạ vào khối nhân cứng (DSP/MULT) của GW1NSR-4. Hãy kiểm tra trong báo cáo tổng hợp (synthesis report) của Gowin EDA.

## 6. Cấu trúc file

```
.
├── gemm_array.v       # RTL chính
├── tb_gemm_array.v    # Testbench tự kiểm tra
└── README.md
```

## 7. Testbench

`tb_gemm_array` so sánh kết quả phần cứng với mô hình tham chiếu trong testbench. Nội dung kiểm tra:

- Bias được nạp đúng khi `clear`.
- Kết quả sau K chu kỳ khớp mô hình tham chiếu cho cả 16 lane.
- `tick` không lên sớm, lên đúng lúc có kết quả cuối, và chỉ có **đúng 1 xung** mỗi block.
- `result_out` được giữ nguyên khi dữ liệu rác tiếp tục đưa vào.
- Các block chạy liên tiếp (back-to-back) và các giá trị K khác nhau: 25, 4, 1, 150.
- Trường hợp biên có dấu: toàn bộ -128 × -128 và +127 × +127.

### Chạy mô phỏng

Với Icarus Verilog:

```bash
iverilog -o sim gemm_array.v tb_gemm_array.v
vvp sim
gtkwave tb_gemm_array.vcd   # xem dạng sóng (tuỳ chọn)
```

Kết quả mong đợi in ra cuối cùng: `*** TEST PASSED ***`.

Có thể dùng thêm ModelSim/Questa hoặc mô phỏng tích hợp trong Gowin EDA.

## 8. Tích hợp trong hệ thống LeNet-5

```
16 bias INT32 ──► ┐
K (INT8) ───────► ├─► GEMM array ──result──► Out_buffer
Ping-pong buf ──► ┘        │  ▲
(K×16 INT8)             tick│  │clear
                           ▼  │
        DMA ─────────► Controller ──address/save──► Out_buffer
                                  └──done
```

- **DMA** đổ dữ liệu vào ping-pong buffer.
- **Controller** phát `clear`, chạy bộ đếm địa chỉ, nhận `tick`, rồi phát `save` / `address` cho `Out_buffer`.

## 9. Việc có thể làm tiếp

- Thêm tín hiệu `valid` / `enable` để dừng pipeline khi dữ liệu chưa sẵn sàng.
- Thêm bước **ReLU / requantize** (INT32 → INT8) ở đầu ra của mỗi layer.
- Pipeline thêm 1 tầng giữa bộ nhân và bộ cộng nếu cần tăng tần số.
