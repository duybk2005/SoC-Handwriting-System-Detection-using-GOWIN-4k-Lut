# Hiển thị chữ số lên HDMI trên Tang Nano 4K (Gowin RTL)

Dự án viết bằng Verilog trên kit **Sipeed Tang Nano 4K** (FPGA Gowin GW1NSR-LV4C). Module `svo_digit` nhận một ngõ vào **10 bit one-hot** (ví dụ kết quả nhận diện chữ số từ một mạng deep learning) và **vẽ chữ số tương ứng lên màn hình qua cổng HDMI**, thay cho bảng màu cố định của project mẫu.

## Bối cảnh

Nhiệm vụ gồm hai phần:

1. **Hiểu kiến trúc HDMI + camera IP** trên Gowin: nhận ảnh từ camera theo thời gian thực, xử lý trên kit, xuất ra HDMI. Phần này đã hoàn thành với hai project mẫu chạy tốt trên kit:
   - **Project A**: xuất một bảng màu cố định ra HDMI (project này được dùng làm nền cho repo này).
   - **Project B**: nhận hình từ camera rồi xuất thẳng ra HDMI.
2. **Viết module RTL riêng để hiển thị chữ số lên HDMI** (phần chính của repo này).
   - Ngõ vào: `digit_in[9:0]`, một dây logic 10 bit.
   - Quy ước one-hot: bit `k` bằng 1 nghĩa là số `k`. Ví dụ `0000001000` (bit 3 bật) là số **3**.
   - Ngõ ra: chữ số hiện trên màn hình HDMI. Có thể xem nó như một khối *decoder* nối với bộ vẽ hình.

## Kiến trúc

Project A dựa trên lõi video **SVO (Simple Video Out)** của Clifford Wolf. Luồng dữ liệu ban đầu:

```
svo_tcard (tạo bảng màu) → svo_enc → svo_tmds → OSER10 → ELVDS_OBUF → HDMI
```

Các khối truyền dữ liệu với nhau theo kiểu **AXI-stream** (`tvalid`, `tready`, `tdata` 24 bit `{B,G,R}`, `tuser[0]` = bắt đầu frame). Khối `svo_enc` lo toàn bộ phần đồng bộ (`hsync`, `vsync`, `de`) nên khối nguồn hình chỉ cần đẩy pixel đúng thứ tự.

Thay đổi duy nhất về kiến trúc: **thay `svo_tcard` bằng `svo_digit`**, hai khối có cùng giao diện AXI-stream nên các khối phía sau không cần sửa.

```
digit_in[9:0] → [đồng bộ 2 FF] → [decoder one-hot → 7 đoạn] → [vẽ 7 hình chữ nhật] → AXI-stream → svo_enc → ... → HDMI
```

Độ phân giải mặc định của project: **640x480 @ 60 Hz** (`SVO_MODE = "640x480V"`).

## Module `svo_digit.v`

Module gồm bốn phần:

1. **Đồng bộ ngõ vào.** `digit_in` đến từ bên ngoài và không cùng clock với `clk_pixel`, nên đi qua 2 flip-flop để tránh metastability.
2. **Decoder one-hot → 7 đoạn.** Dùng `case` đầy đủ để ánh xạ 10 giá trị one-hot thành 7 bit `{g,f,e,d,c,b,a}` (đoạn nào sáng). Giá trị không hợp lệ (không có bit nào bật hoặc nhiều bit bật cùng lúc) sẽ hiển thị **dấu gạch ngang**.
3. **Vẽ chữ số kiểu LED 7 đoạn.** Mỗi đoạn là một hình chữ nhật; pixel nào nằm trong đoạn đang sáng thì tô trắng, còn lại tô đen. Không cần font ROM hay bitmap, chỉ cần so sánh toạ độ `(hcursor, vcursor)`.
4. **Giao tiếp AXI-stream.** Bộ đếm pixel `hcursor`, `vcursor` chạy theo cùng nhịp với `svo_tcard` gốc; `tuser[0]` báo pixel đầu tiên của frame.

Kích thước và vị trí chữ số tự tính theo độ phân giải, đặt ở giữa màn hình:

| Tham số | Công thức | Với 640x480 |
|---|---|---|
| Rộng `W` | `HOR_PIXELS / 4` | 160 |
| Cao `H` | `VER_PIXELS / 2` | 240 |
| Dày nét `T` | `W / 5` | 32 |
| Vị trí `X0`, `Y0` | căn giữa | 240, 120 |

### Tham số

| Tham số | Ý nghĩa |
|---|---|
| `AUTO_TEST = 1` | Module tự đếm 0→9 (khoảng 1 giây mỗi số theo tính toán với pixel clock khoảng 25 MHz), bỏ qua `digit_in`. Dùng để kiểm tra đường hiển thị mà không cần nối chân. |
| `AUTO_TEST = 0` | Chữ số hiện theo `digit_in` thật (cấu hình hiện tại của project). |

## Các file thay đổi so với project mẫu

| File | Thay đổi |
|---|---|
| `svo_digit.v` | **Thêm mới**: module vẽ chữ số. |
| `svo_hdmi.v` | Thay instance `svo_tcard` bằng `svo_digit`; thêm cổng `input [9:0] digit_in`. |
| `top.v` | Thêm cổng `input [9:0] digit_in` và nối xuống `svo_hdmi`. |
| `hdmi.cst` | Thêm ràng buộc chân cho `digit_in[9:0]`. |

Các file còn lại (`svo_enc.v`, `svo_tmds.v`, PLL, clock divider, ...) giữ nguyên.

## Gán chân `digit_in` (Bank 3, 1.8V)

`digit_in` dùng 10 chân của **Bank 3**, đều nằm trên header **P6**:

| Bit | Chân FPGA | Ghi chú |
|---|---|---|
| `digit_in[0]` | 23 | |
| `digit_in[1]` | 22 | |
| `digit_in[2]` | 21 | |
| `digit_in[3]` | 20 | |
| `digit_in[4]` | 19 | |
| `digit_in[5]` | 18 | |
| `digit_in[6]` | 17 | |
| `digit_in[7]` | 13 | |
| `digit_in[8]` | 16 | |
| `digit_in[9]` | 15 | Cũng là nút KEY2 (có điện trở kéo lên 1.8V) |

Ràng buộc: `IO_TYPE=LVCMOS18`, `PULL_MODE=DOWN` (riêng bit 9 dùng `PULL_MODE=NONE` vì đã có điện trở kéo lên sẵn trên board).

### Lưu ý về điện áp và phần cứng

- **Bank 3 chạy 1.8V.** Không đưa 3.3V (hoặc 5V) trực tiếp vào các chân này. Nếu nguồn tín hiệu là 3.3V, cần cầu chia điện trở hoặc mạch chuyển mức. Phải nối chung GND giữa hai bên.
- Các chân Bank 3 vốn là dữ liệu camera (`PIXDATA`). Khi dùng `digit_in`, **hãy tháo module camera** khỏi kit để nó không đẩy tín hiệu vào các chân này.
- Do chân 15 (bit 9) có điện trở kéo lên, **khi để hở ngõ vào, màn hình hiển thị số 9**. Bấm giữ KEY2 sẽ kéo bit 9 về 0.

## Cách build và chạy

1. Mở project trong **Gowin EDA**, thêm `svo_digit.v` vào project.
2. Đảm bảo `hdmi.cst` có đủ ràng buộc chân như trên.
3. Synthesize, Place & Route, rồi nạp bitstream lên kit.
4. Cắm cáp HDMI vào màn hình. Kết quả mong đợi: nền đen, một chữ số trắng kiểu LED 7 đoạn ở giữa màn hình.

Để chỉ kiểm tra phần hiển thị (chưa cần nối chân), đặt `AUTO_TEST = 1`: chữ số sẽ tự đổi 0→9 liên tục.

## Trạng thái hiện tại

- Chế độ `AUTO_TEST = 1` đã chạy trên kit: chữ số hiển thị và đổi số trên HDMI.
- Ở cấu hình `AUTO_TEST = 0` cùng với cổng `digit_in` và ràng buộc chân, project **build không báo lỗi**.
- Chưa hoàn tất: kiểm tra từng bit `digit_in` bằng dây jumper trên phần cứng, và nối với nguồn dữ liệu thật (kết quả nhận diện từ mạng deep learning).

## Hướng phát triển

- Kiểm tra toàn bộ 10 bit trên phần cứng và ghi lại kết quả.
- Chốt cách nhận kết quả nhận diện: 10 dây song song, hoặc gửi 1 byte qua **UART** từ máy tính (cần bộ chuyển USB–UART ngoài, thêm module UART RX rồi chuyển thành one-hot). Cách UART chỉ tốn 1 chân và không cần chuyển mức 10 đường.
- Nếu mạng chạy ngay trong FPGA: bỏ cổng ngoài `digit_in`, nối trực tiếp ngõ ra của khối mạng vào `svo_digit` bằng dây nội bộ.
- Hiển thị thêm nhiều chữ số hoặc nhãn, đổi màu chữ, chuyển sang font bitmap.

## Ghi công

Lõi video dựa trên **SVO – Simple Video Out FPGA Core** © 2014 Clifford Wolf (giấy phép ISC, xem phần đầu các file `svo_*.v`).
