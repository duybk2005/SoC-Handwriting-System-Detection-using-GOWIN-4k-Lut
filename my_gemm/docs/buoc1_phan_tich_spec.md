# Bước 1 – Phân tích spec khối GEMM

Nguồn spec: `LeNet/Detail.pptx` (slide 14–21), `LeNet/detail.md`, ảnh trong `LeNet/image/detail/`
(Figure 1 = `1792328797739.png`, bản mới nhất có Out_buffer, save, address).
Nguồn dữ liệu: `LeNet/training/outputs/lenet5/mem_20260930_173742_222887/` (file .mem + manifest.json).

Viết tắt nguồn: **S14** = slide 14, **DM** = detail.md, **B1/B2** = Bảng 1/Bảng 2 trong detail.md,
**TF n** = mục n của "Timing Flow" trong detail.md, **GT n** = "Giả thuyết n" trong detail.md,
**F1** = Figure 1, **MF** = manifest.json.

---

## a) GEMM tính gì

### Công thức (DM dòng 9; S15, S16, S18)
- Large N (Conv, Phase 1–2): `A[MxN] = W[MxK] * P[KxN] + B[M] * 1^T_N`
  (mọi cột của hàng m cộng cùng một bias B[m]).
- Fully Connected (N = 1, Phase 3–5): `A[M] = W[MxK] * P[Kx1] + B[M]`

### Cách tính (S14, S15, S16, S17, TF 4)
- 16-lane MAC array, Output-Stationary (S14): mỗi lane giữ 1 thanh ghi tích lũy INT32 cố định
  cho 1 phần tử output, chạy K nhịp ("Loop for K times to finished a block", S15/S16).
- Mỗi nhịp: 1 giá trị `broadcast` (INT8) nhân với 16 giá trị `element` (INT8), cộng vào 16 accumulator (TF 4).
- **Conv (S15)**: 16 lane = 16 cột (pixel) liên tiếp của cùng hàng m.
  broadcast = `W[m,k]`, element = `P[k, n0..n0+15]`, bias 16 lane bằng nhau = `B[m]` (S17).
- **FC (S16)**: 16 lane = 16 hàng (neuron) liên tiếp.
  broadcast = `P[k]` (V / H3 / H4), element = `W[m0..m0+15, k]`, bias = `B[m0..m0+15]`, mỗi lane một giá trị (S17).

### Bảng 5 phase (B1; công thức S18/ảnh 1792325447910, 1792325452685)

| Phase | Lớp | M, K, N | Mode | Broadcast buffer | Element buffer (n=4) | Bias | Out_buffer | Số block (*) | Số bank/block (*) |
|---|---|---|---|---|---|---|---|---|---|
| 1 | C1 | 6, 25, 784 | Conv | W1[6x25] Direct 150B | 16 cột của P1[25x784] | B1, 6 INT32 | Acc1[6x784], Ping-Pong 2 x 1/4 | 6 x 49 = 294 | 7 (bank cuối 1 nhịp) |
| 2 | C3 | 16, 150, 100 | Conv | W2 1 hàng, Ping-Pong 2 x 150B | 16 cột của P2[150x100] | B2, 16 INT32 | Acc2[16x100], Ping-Pong 2 x 1/4 | 16 x 7 = 112 (block cuối 4 cột) | 38 (bank cuối 2 nhịp) |
| 3 | C5/FC1 | 120, 400, 1 | FC | V[400] Direct | 16 hàng của W3[120x400] | B3, 120 INT32 | Acc3[120] Direct | 8 (block cuối 8 lane) | 100 |
| 4 | F6/FC2 | 84, 120, 1 | FC | H3[120] Direct | 16 hàng của W4[84x120] | B4, 84 INT32 | Acc4[84] Direct | 6 (block cuối 4 lane) | 30 |
| 5 | Output | 10, 84, 1 | FC | H4[84] Direct | 16 hàng của W5[10x84] | B5, 10 INT32 | Logits[10] Direct | 1 (10 lane) | 21 |

(*) do mình tính ra từ M, K, N; spec không ghi.

### Vai trò từng buffer (B2, F1)
- **Bias buffer** (F1: "16 bias INT32"): xuất `bias(16) INT32` vào GEMM array; được nạp vào accumulator khi `clear = 1` (B2 hàng 1, TF 3).
- **Broadcast buffer** (F1: "K INT8"): xuất 1 INT8 mỗi nhịp. Conv giữ trọng số W; FC đảo sang giữ vector V/H3/H4. Chỉ Phase 2 dùng Ping-Pong (B2 hàng 2, GT 3).
- **Element buffer** (F1: "Ping-pong buffer"): xuất `element(16) INT8`. Ping-Pong, mỗi bank 4 nhịp x 16B = 64B, tổng 128B ở mọi phase; đổi bank mỗi 4 nhịp bằng `tick` (B2 hàng 3, TF 4, GT 2).
- **Out_buffer**: nhận `result` INT32 qua `save` + `address`. Phase 1–2: Ping-Pong, mỗi phân vùng = 1/4 output, đầy 1 phân vùng thì module sau lấy on-the-fly. Phase 3–5: Direct (B2 hàng 4, TF 5, GT 3).

### Luồng điều khiển (TF 1–5)
```
start=1 -> controller chốt phase -> chọn (M,K,N) + map buffer        (TF 1)
        -> nạp broadcast (Direct, hoặc bank đầu nếu Phase 2)
        -> lặp cho từng block 16 output:
             nạp bias(16) -> clear=1 (acc <- bias)                    (TF 3)
             K nhịp MAC; mỗi n=4 nhịp: tick=1, đổi Ping<->Pong        (TF 4)
             hết K: save=1 + address, ghi kết quả vào Out_buffer      (TF 5)
        -> hết block cuối: done=1                                     (TF 5)
```

---

## b) Bảng port

### Port ra ngoài khối (khung xám F1)
F1 chỉ vẽ 4 đường ra/vào: `phase`, `start`, `done`, dữ liệu từ HYPERAM. Các port còn lại là GIẢ ĐỊNH (GĐ) cần để mạch chạy được.

| Port | Hướng | Rộng | Nguồn | Mô tả |
|---|---|---|---|---|
| clk | in | 1 | GĐ17 | Clock hệ thống |
| rst_n | in | 1 | GĐ17 | Reset bất đồng bộ, mức thấp |
| phase | in | 3 | F1, TF 1 | 1..5, chọn lớp |
| start | in | 1 | F1, TF 1 | Xung bắt đầu 1 phase |
| done | out | 1 | F1, TF 5 | Phase xong |
| hr_rdata | in | 8 | F1 (HYPERAM -> mux), MF bits_per_word=8 | Byte dữ liệu đọc từ HyperRAM |
| hr_rvalid | in | 1 | GĐ2 | Byte hr_rdata hợp lệ |
| hr_req | out | 1 | GĐ2 | Yêu cầu đọc burst |
| hr_addr | out | 24 | GĐ2 | Địa chỉ byte bắt đầu |
| hr_len | out | 16 | GĐ2 | Số byte của burst |
| hr_ack | in | 1 | GĐ2 | HyperRAM nhận yêu cầu |
| ob_raddr | in | 12 | GĐ14 | Địa chỉ đọc Out_buffer (cho module sau) |
| ob_rdata | out | 32 | GĐ14 | Dữ liệu INT32 đọc ra (trễ 1 clk) |
| ob_part_full | out | 1 | GĐ14, TF 5 | Xung: 1 phân vùng 1/4 output đã đầy (Phase 1–2) |
| ob_part_id | out | 1 | GĐ14 | Phân vùng nào vừa đầy (0 = Ping, 1 = Pong) |

### Tín hiệu nội bộ (theo F1)

| Tín hiệu | Từ -> Tới | Rộng | Nguồn |
|---|---|---|---|
| load_select | controller -> mux | 2 | F1 (GĐ18: mã hóa) |
| bias(16) INT32 | bias buffer -> GEMM array | 16 x 32 | F1, B2 |
| broadcast INT8 | broadcast buffer -> GEMM array | 8 | F1, B2 |
| element(16) INT8 | ping-pong buffer -> GEMM array | 16 x 8 | F1, B2 |
| clear | controller -> GEMM array | 1 | F1, TF 3 |
| tick | GEMM array -> controller | 1 | F1 (chiều mũi tên), TF 4 |
| result | GEMM array -> Out_buffer | 16 x 32 | F1 |
| save | controller -> Out_buffer | 1 | F1, TF 5 |
| address | controller -> Out_buffer | 12 | F1, TF 5 |
| phase -> DMA | ngoài -> DMA | 3 | F1 (phase rẽ nhánh vào DMA) |

---

## c) GIẢ ĐỊNH

Mỗi mục: spec nói gì / mình chọn gì / lý do.

**GĐ1 – Phạm vi khối.** Chọn: khối GEMM = toàn bộ khung xám F1 (mux, bias buffer, broadcast buffer, ping-pong buffer, DMA, controller, GEMM array, Out_buffer). HyperRAM nằm ngoài, testbench giả lập. Requant / ReLU / MaxPool / im2col (Patch) nằm ngoài khối (ảnh công thức: RQ(ReLU(Acc)) làm sau Acc).

**GĐ2 – Giao tiếp HyperRAM.** Spec chỉ vẽ 1 mũi tên dữ liệu. Chọn: giao tiếp burst-read 8-bit đơn giản `hr_req/hr_addr/hr_len/hr_ack` + `hr_rdata/hr_rvalid`, latency bất kỳ. Lý do: HyperRAM là bus 8-bit; MF ghi `bits_per_word = 8`; controller HyperRAM thật sẽ là khối riêng.

**GĐ3 – Bản đồ địa chỉ HyperRAM.** Spec không nói. Chọn: weight/bias theo `MF.hyperram_image.regions` (c1_weight 0, c1_bias 152, c3_weight 176, c3_bias 2576, c5_weight 2640, c5_bias 50640, f6_weight 51120, f6_bias 61200, output_weight 61536, output_bias 62376), để thành `parameter` có thể đổi. Activation (P1, P2, V, H3, H4) do controller ngoài đặt ở vùng `ACT_BASE = 0x10000`. Lý do: DM dòng 11 "controller lớn bên ngoài điều khiển luồng data từ Hyperram vào"; file `model_image.mem` có sẵn đúng layout này.

**GĐ4 – Layout activation.** Chọn: P[KxN] row-major, `P[k][n]` tại `ACT_BASE + k*N + n`, im2col đã làm sẵn bên ngoài; thứ tự hàng `k = c*25 + ky*5 + kx` khớp layout OIHW của weight (MF `conv_weight_address`). V/H3/H4 là vector liên tiếp. Lý do: Conv cần `P[k, n0..n0+15]` liền nhau -> đọc 1 burst 16B.

**GĐ5 – Thứ tự quét block.** Spec không nói rõ. Chọn: Conv quét hàng m ở ngoài, block 16 cột ở trong (m = 0: block 1 .. block N/16, rồi m = 1 ...). FC quét block 16 hàng. Lý do: S15 vẽ block-1 đến block (N div 16)+1 trên cùng một hàng; Broadcast Ping-Pong của Phase 2 giữ "từng hàng của W2" (TF 2) chỉ hợp lý nếu xong hết hàng m mới sang m+1; Out_buffer được ghi liên tục theo địa chỉ m*N + n nên chia phân vùng 1/4 được.

**GĐ6 – Kích thước Element buffer.** F1 ghi "Kx16 INT8", DM/B1/B2 ghi n = 4 (2 x 4 x 16B). Chọn n = 4 theo DM (mô tả chi tiết hơn, có cả bảng dung lượng). Slide 20 (Bank A/B 2KB, Weight Tile 1600B...) khác hẳn B1; coi là bản cũ, slide 21 cũng ghi đây là phần "Require" còn phải thiết kế.

**GĐ7 – Cách nạp 1 bank element.** Chọn: Conv: 1 bank = 4 burst x 16B (`P[k, n0..n0+15]`, k = k0..k0+3). FC: 1 bank = 16 burst x 4B (`W[m, k0..k0+3]`, m = m0..m0+15; W row-major theo MF `linear_weight_address`). Lane hoặc nhịp nằm ngoài ma trận (N, M không chia hết 16; K không chia hết 4) thì DMA ghi 0 và không đọc HyperRAM.

**GĐ8 – Đồng bộ DMA và GEMM array.** GT 2 giả sử DMA nạp xong 64B trong thời gian array chạy 4 nhịp. Với bus 8-bit điều này không đúng: 64B cần ít nhất 32 clk (DDR) hoặc 64 clk (1 byte/clk), trong khi 4 nhịp MAC là 4 clk. Chọn: mỗi bank có cờ valid; array chỉ chạy khi bank đang dùng đã valid (nếu không thì dừng chờ); `tick` đổi bank và trả bank cũ cho DMA nạp tiếp. Lý do: kết quả đúng với mọi tốc độ HyperRAM. Hiệu năng thực tế bị giới hạn bởi băng thông HyperRAM, ghi lại để báo nhóm trưởng.

**GĐ9 – Hướng và thời điểm tick.** F1 vẽ tick đi từ GEMM array sang controller. Chọn: array tự đếm nhịp và phát `tick = 1` sau mỗi n = 4 nhịp, hoặc ở nhịp cuối của K nếu K không chia hết 4 (TF 4).

**GĐ10 – Bias buffer.** F1 ghi "16 bias INT32" (16 thanh ghi), B1 lại cấp phát toàn bộ vector (ví dụ B3 = 480B). Chọn theo F1: 16 thanh ghi INT32, nạp từ HyperRAM trước mỗi block. Conv: đọc 1 giá trị B[m] và nhân bản ra 16 lane. FC: đọc 16 giá trị B[m0..m0+15] (S17). INT32 ghép từ 4 byte little-endian (MF `word32_byte_order`). Lý do: khớp sơ đồ phần cứng, ít bộ nhớ; nếu nhóm trưởng muốn lưu cả vector như B1 thì chỉ đổi nguồn nạp.

**GĐ11 – Broadcast buffer.** Chọn: RAM 400B (lớn nhất, Phase 3). Phase 1 nạp trọn 150B một lần; Phase 2 chia 2 nửa 150B, nạp hàng m+1 trong lúc tính hàng m; Phase 3–5 nạp vector một lần (TF 2, GT 3). S17 ghi "Broadcast remain unchange during K cycles": mình hiểu là nội dung buffer không đổi trong 1 block, còn giá trị đưa ra ở nhịp k là phần tử thứ k (nếu giá trị không đổi thì công thức tích ma trận sai).

**GĐ12 – Có dấu / không dấu.** B2 ghi "INT8/UINT8". Weight là INT8 có dấu. P1 là pixel UINT8 0..255 (MF `raw_dtype = uint8`, padding 0); các activation sau ReLU + requant nằm trong 0..127. Chọn: nhân 9-bit có dấu, weight sign-extend, activation zero-extend. Toán hạng activation: Conv là element, FC là broadcast. Lý do: nếu coi P1 là INT8 có dấu thì pixel > 127 bị tính sai.

**GĐ13 – Tràn số.** Accumulator INT32, không bão hòa (wrap-around). MF `bounds` ghi `int32_safe = true` cho mọi lớp.

**GĐ14 – Out_buffer.** Chọn: 1 RAM dual-port 32-bit, 2352 word (= 2 x 1176, lớn nhất ở Phase 1). Phía ghi: `save` + `address`, 1 word/clk, chỉ ghi lane hợp lệ (tối đa 16 clk/block); kết quả array được chốt sang thanh ghi trước, để array chạy block kế tiếp song song. Phase 1–2: địa chỉ = (m*N + n) mod 2Q, Q = 1/4 output (1176 word ở Phase 1, 400 word ở Phase 2); đầy 1 phân vùng thì phát xung `ob_part_full` + `ob_part_id`. Không có tín hiệu chờ ngược từ module sau (GT 3: module sau nhanh hơn). Phase 3–5: địa chỉ = m. Thêm cổng đọc `ob_raddr/ob_rdata` (F1 không vẽ, nhưng module sau cần). Lưu ý: Q = 1176 không chia hết 16 nên 1 block có thể ghi vắt qua 2 phân vùng; ghi tuần tự nên không sao.

**GĐ15 – SRAM 12 KB dùng chung.** TF 1 / B1 mô tả 1 vùng 12 KB với dải địa chỉ hex. Chọn: hiện thực các buffer thành bộ nhớ riêng như F1 vẽ; dải địa chỉ B1 chỉ dùng để báo cáo ngân sách. Lý do: 1 SRAM 1 cổng không cấp đủ bias + broadcast + element + ghi output trong cùng 1 nhịp.

**GĐ16 – start / done.** Chọn: `start` là xung 1 clk, chỉ nhận khi khối đang rảnh; `phase` được chốt tại lúc start; phase ngoài 1..5 bị bỏ qua. `done` giữ mức 1 từ khi ghi xong output cuối tới lần `start` kế tiếp.

**GĐ17 – Clock / reset.** Một miền clock; `rst_n` bất đồng bộ, tích cực mức thấp.

**GĐ18 – load_select và phân xử HyperRAM.** Chọn: `load_select` 2 bit (0 = bias, 1 = broadcast, 2 = element/DMA). Controller vừa điều khiển mux vừa phân xử 1 cổng HyperRAM: ưu tiên element (thiếu là array phải dừng); nạp broadcast Pong của Phase 2 chen vào lúc rảnh.

---

## d) Kế hoạch

### Chia khối RTL (`my_gemm/rtl/`)

| File | Nội dung |
|---|---|
| gemm_defs.vh | Bảng (M, K, N, mode, địa chỉ) cho 5 phase |
| gemm_array.v | 16 lane MAC 9x9 có dấu + 16 accumulator INT32; clear nạp bias; tự đếm nhịp, phát tick |
| bias_buf.v | 16 x INT32, ghép byte little-endian, chế độ nhân bản (Conv) / 16 giá trị (FC) |
| bcast_buf.v | RAM 400 x 8, 2 nửa cho Ping-Pong Phase 2 |
| elem_pingpong.v | 2 bank x 4 nhịp x 128-bit, cờ valid từng bank |
| gemm_dma.v | Sinh địa chỉ burst để nạp element (GĐ7) |
| out_buffer.v | RAM dual-port 2352 x 32, chia phân vùng Ping-Pong, cổng đọc |
| gemm_ctrl.v | FSM chính, đếm m / block / k, phát clear / save / address / done, load_select, phân xử HyperRAM |
| gemm_core.v | Top, nối dây đúng Figure 1 |

### Testbench (`my_gemm/tb/`, `my_gemm/sim/`)
- `hyperram_model.v`: mảng byte, `$readmemh` nạp `model_image.mem` tại địa chỉ 0 (weight/bias thật, đúng layout MF); testbench ghi activation vào `ACT_BASE`; latency chỉnh được, có chế độ ngẫu nhiên.
- `tb_gemm_array.v`: test riêng array (clear nạp bias, góc -128 x 255, 127 x 255, tick mỗi 4 nhịp, K lẻ).
- `tb_gemm.v`: task `run_phase(p)`; golden `W*P + B` tính bằng vòng lặp từ cùng mảng bộ nhớ; đọc output qua `ob_raddr/ob_rdata` (Phase 1–2 đọc từng phân vùng khi có `ob_part_full`); so từng phần tử, in PASS/FAIL + tổng số lỗi.
- `sim/run.do`: vlib / vlog / vsim, lưu waveform `.wlf` + `wave.do`.
- Công cụ: ModelSim ASE 13.0sp1 (`C:\altera\13.0sp1\modelsim_ase`) đã có trong PATH.

### Các test

| # | Test | Dữ liệu | Kiểm tra |
|---|---|---|---|
| T0 | Unit gemm_array | vector tự tạo | MAC, có dấu / không dấu, tick, clear |
| T1 | Phase 5 (M=10, K=84, N=1) | W5/B5 thật; H4: ngẫu nhiên 0..127, toàn 127, toàn 0 (ra đúng bias) | 10 logits |
| T2 | Phase 4 | W4/B4 thật; H3 ngẫu nhiên | 84 output, block cuối 4 lane |
| T3 | Phase 3 | W3/B3 thật; V ngẫu nhiên | 120 output, block cuối 8 lane |
| T4 | Phase 2 | W2/B2 thật; P2 ngẫu nhiên 0..127 | 1600 output, broadcast Ping-Pong, 4 phân vùng, block cuối 4 cột |
| T5 | Phase 1 | W1/B1 thật; P1 = im2col ảnh thật (`reference_padded_input.mem` mẫu 0, 0..255) + 1 lần ngẫu nhiên 0..255 | 4704 output |
| T6 | Chạy liền 5 phase | như trên | start / done nối tiếp, không kẹt FSM |
| T7 | HyperRAM latency 0 và ngẫu nhiên | T1–T5 | kết quả không đổi (kiểm GĐ8) |

Kiểm thêm ở mọi test: số lần `clear`, `tick`, `save` khớp công thức; `done` lên đúng 1 lần; Phase 1–2 có đúng 4 xung `ob_part_full`; watchdog timeout.

Tùy chọn sau Bước 4 (chỉ đề xuất): nối chuỗi 5 phase với RQ/ReLU/pool viết trong testbench rồi so với `reference_logits.mem`. Phần này ngoài phạm vi GEMM nên chỉ làm nếu được đồng ý.
