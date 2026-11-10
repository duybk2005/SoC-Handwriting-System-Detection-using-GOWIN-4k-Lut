# Bước 4 – Kết quả mô phỏng (ModelSim ALTERA 10.1d)

## Tóm tắt
- T0 (unit test GEMM array): **PASS**.
- T1–T6 với 3 cấu hình HyperRAM (nhanh; latency 0..8 + 30% chu kỳ trống; latency 0..20 + 50% chu kỳ trống): **30/30 PASS**.
- Không phải sửa RTL: lần chạy đầu đã PASS hết.
- Để chắc testbench không "dễ dãi", đã cài 4 lỗi giả vào RTL (mutation test). Testbench bắt được cả 4 lỗi.

## Kết quả T1–T6 (HyperRAM nhanh, `tb_lat0.log`)

| Test | Phase | Dữ liệu | Kết quả | Chu kỳ |
|---|---|---|---|---|
| T1a | 5 (10, 84, 1) | W5/B5 thật, H4 ngẫu nhiên 0..127 | 10/10 đúng | 2 273 |
| T1b | 5 | H4 toàn 127 | 10/10 đúng | 2 273 |
| T1c | 5 | H4 toàn 0 (ra đúng bias) | 10/10 đúng | 2 273 |
| T2 | 4 (84, 120, 1) | W4/B4 thật, H3 ngẫu nhiên | 84/84 đúng | 25 878 |
| T3 | 3 (120, 400, 1) | W3/B3 thật, V ngẫu nhiên | 120/120 đúng | 121 734 |
| T4 | 2 (16, 150, 100) | W2/B2 thật, P2 ngẫu nhiên + 1 xung start giả lúc đang bận | 1600/1600 đúng | 347 675 |
| T5a | 1 (6, 25, 784) | W1/B1 thật, P1 = im2col ảnh MNIST thật (mẫu 0) | 4704/4704 đúng | 163 983 |
| T5b | 1 | P1 ngẫu nhiên 0..255 | 4704/4704 đúng | 163 983 |
| T5c | 1 | P1 toàn 255 (kiểm UINT8) | 4704/4704 đúng | 163 983 |
| T6 | 5 | chạy ngay sau Phase 1 | 10/10 đúng | 2 273 |

Mỗi test còn kiểm tra:
- Số lần `clear` = số block; số `tick` = số block × ceil(K/4); số `save` = M × N.
- `done` lên đúng 1 lần; Phase 1–2 có đúng 4 xung `ob_part_full`, `part_id` luân phiên 0/1.
- HyperRAM không bị đọc ra ngoài vùng nhớ.

## T7 – HyperRAM chậm, ngẫu nhiên

| Cấu hình | Kết quả | Phase 1 / Phase 2 (chu kỳ) |
|---|---|---|
| HR_LAT=0, HR_GAP=0% | 10/10 PASS | 163 983 / 347 675 |
| HR_LAT=8, HR_GAP=30%, SEED=7 | 10/10 PASS | 243 763 / 519 107 |
| HR_LAT=20, HR_GAP=50%, SEED=3 | 10/10 PASS | 354 549 / 758 904 |

Cả 3 cấu hình đều đọc đúng 54 287 burst / 659 058 byte. Cơ chế dừng chờ bằng cờ valid (GĐ8) cho kết quả đúng với mọi tốc độ HyperRAM.

## Mutation test (kiểm tra chính testbench)

| Lỗi cài vào | Test FAIL | Nhận xét |
|---|---|---|
| M1: P coi là số có dấu (vi phạm GĐ12) | T5a, T5b, T5c | Chỉ Phase 1 có pixel > 127, nên chỉ Phase 1 lộ lỗi |
| M2: DMA cộng sai địa chỉ hàng W (FC) | T1a, T1b, T2, T3, T6 | T1c vẫn PASS vì H4 = 0 thì weight sai không ảnh hưởng |
| M3: controller bỏ lane cuối mỗi block | 10/10 | Phát hiện cả qua so phần tử lẫn số lần `save` |
| M4: Phase 2 đọc nhầm nửa Ping/Pong của broadcast | T4 | Sai đúng 800/1600 phần tử = các hàng lẻ |

## Hiệu năng (thông tin để báo nhóm trưởng)
- Với HyperRAM nhanh nhất (1 byte/clk), 5 phase tốn khoảng 664 000 chu kỳ, tức khoảng 13 ms ở 50 MHz.
- Phần lớn thời gian là chờ DMA, đúng như GĐ8. Ví dụ Phase 2 phải đọc lại P2 cho từng hàng của W2 (16 lần × 15 000 byte).

## File
- Log: `sim/t0.log`, `sim/tb_lat0.log`, `sim/tb_lat8_gap30.log`, `sim/tb_lat20_gap50.log`
- Waveform: `sim/gemm_lat0.wlf`, `sim/gemm_lat8_gap30.wlf`, `sim/gemm_lat20_gap50.wlf`, `sim/t0_array.wlf`
- Xem waveform (trong thư mục `my_gemm/sim`): `vsim -view gemm_lat0.wlf -do wave.do`
- Chạy lại: `vsim -c -do run_t0.do` và `vsim -c -do "do run_tb.do 0 0 1 gemm_lat0.wlf"`
