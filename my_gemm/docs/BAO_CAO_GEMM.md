# Báo cáo: Thiết kế và kiểm chứng khối GEMM cho LeNet-5

**Tóm tắt.** Khối GEMM đã được code bằng Verilog-2001 theo Figure 1, `detail.md` và slide 14–21. Kết quả mô phỏng ModelSim:
- 30/30 lượt test PASS, chạy đủ 5 phase với weight/bias thật lấy từ `mem_20260930_173742_222887`. Phase 1 được thử thêm với ảnh MNIST thật.
- Kết quả đúng với mọi tốc độ HyperRAM đã thử.

Tổng hợp Gowin cho GW1NSR-4C dùng 73% logic, 90% BSRAM và 16 DSP; Fmax ước lượng 53.7 MHz.

Có **18 giả định** ở những chỗ spec chưa rõ; mục 8 liệt kê các câu hỏi cần nhóm trưởng xác nhận.

Quy ước ghi nguồn: **S** = slide trong `Detail.pptx`, **DM** = `detail.md`, **B1/B2** = Bảng 1/Bảng 2 trong DM, **TF n** = mục n của "Timing Flow", **GT n** = "Giả thuyết n", **F1** = Figure 1, **GĐ n** = giả định thứ n của nhóm mình.

---

## 1. GEMM tính gì

Khối GEMM tính 2 dạng phép toán (DM dòng 9; S15, S16, S18):

- **Conv (large N):** `A[MxN] = W[MxK] * P[KxN] + B[M] * 1^T_N`
- **FC (N = 1):** `A[M] = W[MxK] * P[Kx1] + B[M]`

Phần cứng là một **16-lane MAC array, Output-Stationary** (S14):
- Mỗi nhịp lấy 1 giá trị `broadcast` nhân song song với 16 giá trị `element`, cộng vào 16 accumulator INT32 (TF 4).
- Một block gồm 16 output, chạy đủ K nhịp thì xong (S15, S16).

| | Conv (Phase 1, 2) | FC (Phase 3, 4, 5) |
|---|---|---|
| 16 lane là | 16 cột liên tiếp của hàng m | 16 hàng liên tiếp |
| broadcast | W[m, k] | V/H[k] |
| element | P[k, n0..n0+15] | W[m0..m0+15, k] |
| bias 16 lane | cùng giá trị B[m] (S17) | B[m0..m0+15] (S17) |

| Phase | Lớp | M, K, N | Broadcast | Out_buffer | Số block | Chu kỳ (*) |
|---|---|---|---|---|---|---|
| 1 | C1 | 6, 25, 784 | W1 150B Direct | Ping-Pong 2 × 1/4 | 294 | 163 983 |
| 2 | C3 | 16, 150, 100 | W2 Ping-Pong 2 × 150B | Ping-Pong 2 × 1/4 | 112 | 347 675 |
| 3 | C5 | 120, 400, 1 | V 400B Direct | Direct | 8 | 121 734 |
| 4 | F6 | 84, 120, 1 | H3 120B Direct | Direct | 6 | 25 878 |
| 5 | Output | 10, 84, 1 | H4 84B Direct | Direct | 1 | 2 273 |

(*) Đo trong mô phỏng với HyperRAM nhanh nhất (1 byte/clk).

---

## 2. Kiến trúc RTL (theo Figure 1)

```
            +--------------------------- gemm_core ------------------------------+
HyperRAM -->| gemm_ldmux --> bias_buf (16 x INT32) --bias(16)--> gemm_array -----+--result--> out_buffer --> ob_rdata
 (hr_*)     |     ^      --> bcast_buf (K INT8) ---broadcast--> (16 MAC)        |  save/address ^
            |     |      --> gemm_dma --> elem_pingpong --element(16)-->        |              |
            | load_select                                     clear |  ^ tick   |              |
            |  gemm_arb <------------- gemm_ctrl (controller) ------+--+--------+--------------+
            +--------------------------^-----^-------------------------------|-----------------+
                                     phase  start                           done
```

| Module | Vai trò |
|---|---|
| `gemm_core.v` | Top, nối dây theo F1 |
| `gemm_ctrl.v` | Controller: FSM IDLE → BC0 → ROW → BIAS → CLR → RUN → DRAIN → SAVE → NEXTB → DONE |
| `gemm_arb.v` | Phân xử một cổng HyperRAM, sinh `load_select`. Ưu tiên bias > broadcast > element |
| `gemm_ldmux.v` | Mux dữ liệu HyperRAM theo `load_select` (F1) |
| `bias_buf.v` | 16 × INT32, ghép byte little-endian. Ở Conv, mỗi byte được ghi vào cả 16 lane |
| `bcast_buf.v` | K INT8, RAM 512 × 8, hai nửa Ping-Pong cho Phase 2 |
| `gemm_dma.v` | Nạp element theo đúng thứ tự tiêu thụ. Conv: 4 burst × 16B; FC: 16 burst × 4B |
| `elem_pingpong.v` | 2 bank × 4 nhịp × 16 byte, mỗi bank có cờ valid |
| `gemm_array.v` | 16 MAC 9 × 9 có dấu, pipeline 2 tầng, phát `tick` mỗi 4 nhịp |
| `out_buffer.v` | RAM dual-port 2352 × 32. Phase 1–2 chia Ping-Pong 2 × 1/4, phát `ob_part_full` |

**Port ra ngoài.**
- Theo F1: `phase[2:0]`, `start`, `done`, dữ liệu HyperRAM.
- Thêm vào (giả định): `clk`, `rst_n`; giao tiếp HyperRAM `hr_req/hr_addr/hr_len/hr_ack/hr_rdata/hr_rvalid`; cổng đọc Out_buffer `ob_raddr/ob_rdata/ob_part_full/ob_part_id`.

**Tín hiệu nội bộ đúng tên F1:** `load_select`, `bias(16)`, `broadcast`, `element(16)`, `clear`, `tick` (đi từ array sang controller), `result`, `save`, `address`.

---

## 3. Luồng hoạt động (TF 1–5)

1. **Khởi động.** Khi `start = 1`, controller chốt `phase` và chọn (M, K, N) cùng các địa chỉ. Sau đó nạp broadcast: W1 (Phase 1), hàng 0 của W2 (Phase 2), hoặc V/H3/H4 (Phase 3–5).
2. **Mỗi block.**
   - Nạp bias. Riêng Conv thì B[m] dùng chung cho cả hàng nên chỉ nạp một lần mỗi hàng.
   - `clear` (acc = bias).
   - Chạy K nhịp MAC. Cứ hết 4 nhịp, `tick` trả bank vừa dùng cho DMA nạp tiếp (đổi Ping ↔ Pong).
   - Hết K nhịp: `save` ghi 16 kết quả, mỗi chu kỳ 1 word.
3. **Phase 2.** Trong lúc tính hàng m, controller nạp ngầm hàng m+1 của W2 vào nửa còn lại của broadcast buffer.
4. **Phase 1–2.** Mỗi khi Out_buffer ghi đầy 1/4 output, khối phát xung `ob_part_full` để module sau đọc on-the-fly.
5. **Kết thúc.** Sau block cuối, `done = 1` và giữ nguyên tới lần `start` kế tiếp.

---

## 4. Các giả định (chi tiết: `docs/buoc1_phan_tich_spec.md`)

| # | Spec chưa rõ / mâu thuẫn | Lựa chọn | Lý do |
|---|---|---|---|
| GĐ1 | Phạm vi khối | Toàn bộ khung xám F1. HyperRAM, RQ/ReLU/pool/im2col nằm ngoài | Theo F1 và các công thức |
| GĐ2 | Giao tiếp HyperRAM | Burst-read 8-bit dạng req/ack + rvalid | HyperRAM là bus 8-bit; controller HyperRAM thật làm riêng |
| GĐ3 | Địa chỉ trong HyperRAM | Weight/bias theo `manifest.json`; activation ở `0x10000` | DM dòng 11: controller ngoài đưa dữ liệu vào |
| GĐ4 | Layout P | P[KxN] lưu theo hàng, im2col làm sẵn bên ngoài, k = c*25 + ky*5 + kx | Mỗi bước Conv đọc được 16 byte liền nhau |
| GĐ5 | Thứ tự quét | Conv: hàng m ở vòng ngoài, block cột ở vòng trong | Theo S15; broadcast Ping-Pong theo hàng W2 (TF 2) |
| GĐ6 | Element buffer: F1 ghi "Kx16", DM ghi n = 4 | n = 4 (2 × 64B) | DM chi tiết hơn; slide 20 coi là bản cũ |
| GĐ7 | Lane/nhịp nằm ngoài ma trận | Không đọc từ HyperRAM, bỏ qua khi lưu kết quả | Tiết kiệm logic; kết quả không đổi |
| GĐ8 | GT 2 cho rằng DMA nạp kịp 64B trong 4 nhịp — sai với bus 8-bit | Mỗi bank có cờ valid; array dừng chờ khi chưa đủ dữ liệu | Đúng với mọi tốc độ HyperRAM (đã kiểm ở T7) |
| GĐ9 | Hướng của `tick` | Array phát `tick` sau mỗi 4 nhịp hoặc ở nhịp cuối của K | Theo mũi tên trên F1 |
| GĐ10 | Bias buffer: F1 ghi 16 × INT32, B1 lưu cả vector | 16 thanh ghi, nạp lại trước mỗi block | Theo F1, S17 |
| GĐ11 | S17 ghi "broadcast không đổi trong K nhịp" | Hiểu là nội dung buffer không đổi trong block | Nếu giá trị không đổi thì công thức tích ma trận sai |
| GĐ12 | INT8 hay UINT8 (B2) | Weight có dấu, activation không dấu | P1 là pixel 0..255 (theo manifest) |
| GĐ13 | Tràn số | INT32, không bão hòa | Manifest ghi `int32_safe` cho mọi lớp |
| GĐ14 | Out_buffer | RAM 2352 word, ghi 1 word/clk, phát `part_full` | Module sau cần biết lúc nào đọc được |
| GĐ15 | SRAM 12 KB dùng chung | Tách thành các buffer riêng như F1 | 1 SRAM 1 cổng không phục vụ đủ trong 1 nhịp |
| GĐ16 | Handshake `start`/`done` | `start` là xung 1 clk; `done` giữ mức 1 | Thuận tiện cho controller ngoài |
| GĐ17 | Clock / reset | 1 miền clock; `rst_n` bất đồng bộ, tích cực mức thấp | — |
| GĐ18 | Mã hóa `load_select` | 2 bit: 0 = bias, 1 = broadcast, 2 = element | — |

**Thay đổi trong lúc hiện thực.** GEMM array thêm 1 tầng pipeline (nhân trước, cộng sau). Lý do: bản chỉ có 1 tầng khiến Gowin gộp nhân và cộng vào khối MULTADDALU, mà chip chỉ có 8 khối loại này. 8 lane còn lại phải dựng bằng logic, làm thiết kế cần 5408 logic, vượt mức 4608 của chip.

---

## 5. Kết quả tổng hợp (Gowin V1.9.11.03, GW1NSR-LV4CQN48PC6/I5, chưa place & route)

| Tài nguyên | Dùng | Tỉ lệ |
|---|---|---|
| Logic (LUT + ALU) | 3355 / 4608 | 73% |
| Register | 2431 / 3573 | 69% |
| BSRAM | 9 / 10 | 90% (Out_buffer dùng 8, broadcast dùng 1) |
| DSP MULT9X9 | 16 | 16 lane |
| Fmax ước lượng | 53.7 MHz | mục tiêu 50 MHz |

---

## 6. Kết quả mô phỏng (ModelSim ALTERA 10.1d)

**Cách kiểm.**
- Testbench tính kết quả chuẩn W*P + B bằng vòng lặp. W và B lấy từ các **file .mem riêng** (`output_weight.mem`, ...), khác với `model_image.mem` mà khối GEMM đọc qua HyperRAM giả lập. Nhờ vậy, nếu khối đọc sai địa chỉ thì testbench sẽ phát hiện.
- So từng phần tử của output.
- Kiểm thêm giao thức: số lần `clear` / `tick` / `save`, `done`, `part_full`.

| Test | Nội dung | Kết quả |
|---|---|---|
| T0 | Unit test GEMM array: giá trị góc có dấu / không dấu, `tick`, `clear` | PASS |
| T1a/b/c | **Phase 5**, W5/B5 thật; H4 ngẫu nhiên / toàn 127 / toàn 0 | 10/10 ×3 |
| T2, T3 | Phase 4, Phase 3 | 84/84, 120/120 |
| T4 | Phase 2, có xung `start` giả lúc khối đang bận | 1600/1600 |
| T5a | Phase 1, P1 = im2col ảnh MNIST thật | 4704/4704 |
| T5b, T5c | Phase 1, P1 ngẫu nhiên 0..255 / toàn 255 | 4704/4704 ×2 |
| T6 | Phase 5 chạy ngay sau Phase 1 | 10/10 |
| T7 | Chạy lại toàn bộ với HyperRAM latency 0..8 (30% chu kỳ trống) và 0..20 (50% chu kỳ trống) | 20/20 PASS |

**Kiểm tra chính testbench (mutation test).** Cố ý cài 4 lỗi vào RTL; testbench bắt được cả 4:

| Lỗi cài vào | Test bị FAIL |
|---|---|
| Coi P là số có dấu | Chỉ Phase 1 (chỉ Phase 1 có pixel > 127) |
| DMA tính sai địa chỉ ở chế độ FC | Các phase FC |
| Bỏ lane cuối của mỗi block | Toàn bộ test |
| Đọc nhầm nửa Ping/Pong ở Phase 2 | Đúng các hàng lẻ (800/1600) |

---

## 7. Hiệu năng và vấn đề mở

**Lượng dữ liệu đọc mỗi ảnh.** 420 618 byte từ HyperRAM, chia theo phase:

| Phase | Byte |
|---|---|
| 1 | 117 774 |
| 2 | 242 464 |
| 3 | 48 880 |
| 4 | 10 536 |
| 5 | 964 |

Số này khớp đúng với bộ đếm trong mô phỏng.

**Thời gian.** 661 543 chu kỳ, tức khoảng **13.2 ms/ảnh** ở 50 MHz, với HyperRAM nhanh nhất. Chỉ 28 154 chu kỳ (4.3%) là MAC thật sự; phần còn lại là chờ DMA.

**Phase 2 tốn nhiều nhất.** P2 bị đọc lại 16 lần, mỗi lần cho một hàng W2.
- Cách giảm: giữ cả W2 (2400B) trong broadcast buffer và đảo thứ tự quét.
- Đổi lại: broadcast buffer to hơn, và không còn khớp với B1.

**Tài nguyên.** Riêng khối GEMM đã dùng 90% BSRAM và 73% logic. Phần camera, HDMI, RQ/pool, controller ngoài có thể không đủ chỗ trên GW1NSR-4C.

**Chưa làm:**
- Place & route.
- Chạy trên board.
- Ghép với controller HyperRAM thật.
- Chạy end-to-end cả 5 phase rồi so với `reference_logits.mem` (cần RQ/ReLU/pool, nằm ngoài phạm vi khối GEMM).

---

## 8. Câu hỏi cho nhóm trưởng

1. **Element buffer:** n = 4 (2 × 64B) theo `detail.md`, hay "Kx16" như trên Figure 1? Slide 20 (Bank 2KB) còn hiệu lực không? (GĐ6)
2. **Tốc độ DMA:** GT 2 (DMA nạp kịp 64B trong 4 nhịp) không đạt được với bus 8-bit. Cách dừng chờ bằng cờ valid có chấp nhận được không, hay cần tăng độ rộng bus / tăng n? (GĐ8)
3. **Bias buffer:** dùng 16 thanh ghi nạp lại mỗi block (F1), hay lưu cả vector (B1, ví dụ 480B ở Phase 3)? (GĐ10)
4. **Ai làm im2col** cho P1/P2, và activation nằm ở đâu trong HyperRAM? (GĐ3, GĐ4)
5. **Module sau Out_buffer:** có cần tín hiệu chờ ngược (backpressure) không, hay mặc định module sau luôn nhanh hơn (GT 3)? (GĐ14)
6. **Giao tiếp với controller HyperRAM thật:** dạng req/ack burst như GĐ2 có phù hợp không?

---

## 9. Thư mục và cách chạy lại

```
my_gemm/
  rtl/   gemm_core.v gemm_ctrl.v gemm_arb.v gemm_ldmux.v bias_buf.v bcast_buf.v
         gemm_dma.v elem_pingpong.v gemm_array.v out_buffer.v gemm_defs.vh
  tb/    hyperram_model.v tb_gemm_array.v tb_gemm.v
  sim/   compile.do run_t0.do run_tb.do wave.do  *.log  *.wlf
  syn/   syn.tcl  (impl/: báo cáo Gowin)
  docs/  buoc1_phan_tich_spec.md buoc2_rtl.md buoc4_ket_qua_mo_phong.md BAO_CAO_GEMM.md
```

Các lệnh chạy trong `my_gemm/sim`:
- Unit test GEMM array: `vsim -c -do run_t0.do`
- Testbench chính, HyperRAM nhanh: `vsim -c -do "do run_tb.do 0 0 1 gemm_lat0.wlf"`
- T7, HyperRAM chậm: `vsim -c -do "do run_tb.do 8 30 7 gemm_lat8_gap30.wlf"`
- Xem waveform: `vsim -view gemm_lat0.wlf -do wave.do`

Tổng hợp chạy trong `my_gemm/syn`: `gw_sh syn.tcl`
