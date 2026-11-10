# Bước 2 – RTL khối GEMM

## File

| File | Vai trò (Figure 1) |
|---|---|
| rtl/gemm_defs.vh | Hằng số, bản đồ địa chỉ HyperRAM (manifest.json, GĐ3) |
| rtl/gemm_core.v | Top, nối dây theo Figure 1 |
| rtl/gemm_ctrl.v | controller: FSM IDLE → BC0 → ROW → BIAS → CLR → RUN → DRAIN → SAVE → NEXTB → DONE |
| rtl/gemm_arb.v | Phân xử cổng HyperRAM, sinh `load_select` (thuộc controller) |
| rtl/gemm_ldmux.v | Mux dữ liệu HyperRAM theo `load_select` |
| rtl/bias_buf.v | 16 bias INT32 |
| rtl/bcast_buf.v | K INT8 (broadcast buffer, 512 x 8) |
| rtl/gemm_dma.v | DMA nạp Ping-pong buffer |
| rtl/elem_pingpong.v | Ping-pong buffer 2 x 4 x 16 byte |
| rtl/gemm_array.v | GEMM array 16 lane MAC, phát `tick` |
| rtl/out_buffer.v | Out_buffer 2352 x INT32, Ping-Pong 2 x 1/4 cho Phase 1–2 |
| syn/syn.tcl | Script tổng hợp thử bằng Gowin |

## Kiểm tra đã làm
- `vlog` (ModelSim ALTERA 10.1d) compile 10 module: 0 lỗi, 0 warning.
- `vsim` elaborate `gemm_core`: 0 warning (không lệch độ rộng port).
- Gowin V1.9.11.03, GW1NSR-LV4CQN48PC6/I5, chỉ chạy tổng hợp (chưa place & route):

| Tài nguyên | Dùng | Tỉ lệ |
|---|---|---|
| Logic (LUT + ALU) | 3355 / 4608 | 73% |
| Register | 2431 / 3573 | 69% |
| BSRAM | 9 / 10 | 90% (Out_buffer 8, broadcast 1) |
| DSP MULT9X9 | 16 | 16 multiplier của 16 lane |
| Fmax ước lượng | 53.7 MHz | ràng buộc mặc định 50 MHz |

## Thay đổi so với Bước 1
1. **GEMM array có 2 tầng pipeline**: tầng 1 nhân và chốt tích, tầng 2 cộng vào acc.
   - Lý do: nếu để nhân và cộng chung một tầng, Gowin gộp thành MULTADDALU18X18 (chỉ có 8 khối), 8 lane còn lại dựng bằng logic → vượt 4608 LUT (5408).
   - Hệ quả: thêm tín hiệu `busy` (array → controller) và trạng thái `DRAIN` chờ 1 nhịp trước khi `save`.
2. **GĐ7 sửa lại**: lane hoặc nhịp nằm ngoài ma trận **không** được ghi 0 nữa, mà giữ giá trị cũ trong buffer.
   - Kết quả không bị ảnh hưởng: array chỉ chạy đúng K nhịp và controller chỉ lưu các lane hợp lệ.
   - Bỏ việc ghi 0 giúp bớt logic.
3. **bias_buf**: ở Conv, mỗi byte bias được ghi đồng thời vào cả 16 lane ngay khi nạp, thay cho mux nhân bản ở đầu ra (564 → 94 LUT).
4. **DMA**: chốt `nv`/`gl` vào thanh ghi để rút ngắn đường tổ hợp (Fmax 47.6 → 53.7 MHz).

## Chưa làm / cần lưu ý
- Chưa mô phỏng chức năng (Bước 3–4).
- Chưa place & route. Logic 73% và BSRAM 90% chưa tính các khối khác của hệ thống (camera, HDMI, RQ, ...), nên có thể phải chia sẻ tài nguyên.
- Element buffer đang tốn 1024 flip-flop: Gowin không tự map mảng 8 x 8 thành LUT-RAM. Nếu cần tiết kiệm, có thể gọi trực tiếp primitive RAM16SDP4.
