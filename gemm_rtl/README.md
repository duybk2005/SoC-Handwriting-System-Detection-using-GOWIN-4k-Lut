# GEMM Array (16-lane INT8 MAC)

Khối **GEMM Array** nằm trong bộ CORE của bộ tăng tốc suy luận CNN (kiểu LeNet-5). Khối này dùng chung cho phép chập và phép nhân ma trận–vector, viết bằng Verilog.

## Vai trò trong kiến trúc

```
HyperRAM -> DMA -> [Bias | Broadcast | Ping-pong Element] -> GEMM array -> Out_buffer
                                                                ^   |
                                                         clear  |   | tick
                                                           controller
```

GEMM array thực hiện hai dạng phép tính:

- `A[MxN] = W[MxK] * P[KxN] + B[M]·1ᵀ` (phase 1, 2: chập, N lớn, M ≤ 16)
- `A[M] = W[MxK] * P[Kx1] + B[M]` (phase 3, 4, 5: fully-connected, N = 1)

Mỗi nhịp clock, khối nhận **1 phần tử broadcast** nhân song song với **16 phần tử element**, rồi cộng dồn vào **16 thanh ghi tích lũy INT32**.

## Giao tiếp

| Cổng | Hướng | Độ rộng | Mô tả |
|---|---|---|---|
| `clk` | in | 1 | Clock |
| `rst_n` | in | 1 | Reset bất đồng bộ, active low |
| `clear` | in | 1 | Từ controller: nạp lại bias vào thanh ghi tích lũy, xóa bộ đếm n |
| `bias` | in | 16 × 32 | `bias(16) INT32` |
| `broadcast` | in | 8 (signed) | `broadcast INT8` |
| `element` | in | 16 × 8 | `element(16) INT8` từ Ping-pong buffer |
| `tick` | out | 1 | Tới controller: đã xong n bước, đảo vùng Ping ↔ Pong |
| `result` | out | 16 × 32 | 16 giá trị tích lũy INT32 tới Out_buffer |

Các bus được gộp phẳng (flatten): lane `i` nằm ở `bus[i*W +: W]`.

## Tham số

| Tham số | Mặc định | Ý nghĩa |
|---|---|---|
| `LANES` | 16 | Số lane MAC song song |
| `N_STEP` | 4 | Số bước tích lũy giữa hai lần `tick` (n-loop) |

## Nguyên lý hoạt động

1. **`clear = 1`**: `acc[i] <= bias[i]`, bộ đếm n về 0 và `tick` về 0. Controller bật `clear` trước mỗi vòng K-loop.
2. **Tích lũy**: mỗi nhịp sau `clear`, `acc[i] <= acc[i] + broadcast * element[i]`. Tích INT8×INT8 là INT16, được mở rộng dấu lên INT32 trước khi cộng.
3. **`tick`**: sau mỗi `N_STEP` nhịp tích lũy, `tick` lên 1 trong một chu kỳ. Controller dùng xung này để đảo vùng Ping/Pong của Element buffer. Lúc đó `result` đã chứa kết quả của đủ n bước.
4. **Xuất kết quả**: sau khi đủ K bước, controller bật `save` và cấp `address` để ghi `result` vào `Out_buffer`. Việc này nằm ngoài khối GEMM.

## Lưu ý khi sử dụng

- Sơ đồ không có cổng enable, nên khối tích lũy liên tục sau `clear`. Controller cần bật `save` đúng thời điểm sau bước K, hoặc cho `broadcast = 0` khi rảnh để `acc` không đổi.
- Dữ liệu được hiểu là **signed INT8**. Nếu cần UINT8 thì phải sửa phép nhân.
- `result` là giá trị thanh ghi tích lũy trực tiếp, chưa qua requantize hay activation.

## Cấu trúc file

| File | Mô tả |
|---|---|
| `gemm_array.v` | RTL của khối GEMM array |
| `tb_gemm_array.v` | Testbench tự kiểm tra (in `PASS` hoặc `FAIL`) |

## Mô phỏng

Ví dụ với Icarus Verilog:

```bash
iverilog -o sim gemm_array.v tb_gemm_array.v
vvp sim
```

Testbench nạp bias, chạy 8 bước tích lũy với `broadcast = 3`, kiểm tra 16 lane khớp giá trị kỳ vọng và kiểm tra `tick` xuất hiện đúng 2 lần.
