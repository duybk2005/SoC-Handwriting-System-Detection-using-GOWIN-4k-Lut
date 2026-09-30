# Architecture Overview: Real-Time Camera to HDMI Output System

Hệ thống được thiết kế trên dòng FPGA Gowin GW1NSR-4C (Kit Tang Nano 4K), thực hiện chức năng thu nhận tín hiệu hình ảnh thời gian thực từ cảm biến CMOS OV2640, lưu trữ qua bộ nhớ HyperRAM ngoài và xuất hình ảnh hiển thị lên màn hình thông qua chuẩn giao tiếp HDMI (DVI/TMDS).

Toàn bộ vi kiến trúc (Microarchitecture) được đóng gói trong Top module `video_top`, phân chia rõ ràng thành các tầng xử lý dữ liệu (Stages) và khối quản lý xung nhịp/khôi phục trạng thái (Clock & Reset Management).
<img width="2756" height="1521" alt="image" src="https://github.com/user-attachments/assets/3e802155-0018-402c-9a89-392e62bbfe00" />

---

## 1. System Pipeline Stages

### Stage 1: Input & Camera Control
Tầng đầu vào chịu trách nhiệm khởi tạo cấu hình cho cảm biến ảnh và đóng gói dữ liệu điểm ảnh đầu vào:
* **OV2640_Controller**: Khởi tạo cấu hình cho cảm biến OV2640 thông qua giao tiếp I2C/SCCB (`I2C_Interface` với địa chỉ `0x60`). Khối `OV2640_Registers` lưu trữ mảng Look-Up Table (LUT) chứa các thông số định dạng cấu hình. Module cung cấp xung nhịp `XCLK` ($12.375\text{ MHz}$) cho cảm biến.
* **cam_data_pack**: Nhận dữ liệu điểm ảnh thô `PIXDATA[9:0]` kèm các tín hiệu đồng bộ dòng/khung (`HREF`, `VSYNC`) và xung nhịp `PIXCLK` từ cảm biến. Module chuyển đổi định dạng từ RAW10 sang RGB565, đóng gói thành đường truyền 16-bit `cam_data[15:0]`.
* **testpattern_inst**: Khối phát tín hiệu thử nghiệm nội bộ, tạo ra dải màu chuẩn (Test Pattern) ở độ phân giải $640 \times 480$ ($H_{total} = 1650$) trên tần số xung nhịp `pix_clk` ($27\text{ MHz}$).

### Stage 2: Multiplexer (MUX 2:1)
* Mối quan hệ giữa luồng dữ liệu thực tế từ camera và luồng dữ liệu thử nghiệm được điều khiển thông qua khối `key_flag_inst` (xử lý chống rung phím bấm `key`).
* Tín hiệu `key_flag` đóng vai trò là luồng điều khiển cho MUX 2:1 để lựa chọn nguồn dữ liệu đầu vào:
  * `0`: Luồng dữ liệu thực tế từ camera OV2640.
  * `1`: Luồng dữ liệu kiểm thử từ `testpattern_inst`.

### Stage 3: Memory Buffer (HyperRAM Storage)
Để giải quyết sự lệch pha xung nhịp giữa tốc độ thu nhận của camera và tốc độ quét hiển thị HDMI, hệ thống sử dụng chip nhớ HyperRAM/PSRAM ngoài FPGA làm bộ đệm khung (Frame Buffer):
* **Video_Frame_Buffer_Top**: IP Core đóng vai trò điều khiển bộ đệm khung, tích hợp Asynchronous FIFOs ở cả cổng ghi (`vin`) và cổng đọc (`vout`) cùng bộ điều khiển DMA (`dma_ck`).
  * Cổng ghi (`vin`): Nhận dữ liệu `16-bit` từ Stage 2, đồng bộ theo xung `ch0_vfb_clk` (`PIXCLK` hoặc `l_clk`).
  * Cổng đọc (`vout`): Xuất dữ liệu đồng bộ theo xung đọc `ch0_vfb_clk` (`pix_clk`).
* **HyperRAM_Memory_Interface_Top**: IP Core của Gowin thực hiện giao tiếp vật lý (PHY) với chip HyperRAM bên ngoài thông qua bus dữ liệu `O_hram_dq[7:0]` và các tín hiệu điều khiển (`O_hram_ck`, `O_hram_cs_n`, `O_hram_rwds`). Bộ nhớ vận hành ở tần số xung nhịp $159\text{ MHz}$ (`memory_clk`), hỗ trợ truy xuất theo chế độ Burst ($128\text{ Bytes}$).

### Stage 4: Synchronization & Display Output
Tầng cuối cùng đảm nhiệm việc tái tạo định dạng hiển thị và chuyển đổi tín hiệu sang chuẩn vi sai HDMI:
* **RGB565 $\rightarrow$ RGB888**: Chuyển đổi không gian màu từ 16-bit (`RGB565`) sang 24-bit (`RGB888`) bằng cách bù các bit thấp bằng $0$ (`den = 0 -> 24'h000000`).
* **syn_gen_inst**: Module khởi tạo các tín hiệu định thì khung hình (Sync Generator). Tạo các tín hiệu đồng bộ ngang/dọc (`syn_off_h`, `syn_off_v`, `out_de`) hỗ trợ bảng định thì $1650 \times 750$, hiển thị khung hình $1280 \times 720$ (hoặc vùng quét $640 \times 480$) hoạt động trên xung `pix_clk`.
* **Pout_dn**: Trễ dữ liệu và tín hiệu đồng bộ $2$ nhịp xung nhằm đảm bảo việc căn chỉnh thời gian (Timing Alignment) chính xác trước khi đưa vào khối phát.
* **DVI_TX_Top**: Module đóng gói dữ liệu và chuyển đổi chuẩn tín hiệu:
  * Mã hóa không gian màu và dữ liệu điều khiển thành mã 10-bit ($8\text{b}/10\text{b}\text{ encoder}$).
  * Bộ biến đổi song song sang nối tiếp (Serializer) chuyển đổi dữ liệu sử dụng bộ xung đôi: xung `pix_clk` ($74.25\text{ MHz}$) và xung tốc độ cao `serial_clk` ($371.25\text{ MHz}$).
  * Xuất tín hiệu định dạng vi sai TMDS ra cổng physical HDMI (`O_tmds_clk_p/n`, `O_tmds_data_p/n[2:0]`).

---

## 2. Clock & Reset Architecture

### Clock Domains
Hệ thống quản lý nhiều vùng xung nhịp độc lập (Clock Domains) được tổng hợp thông qua các khối IP PLL của Gowin:
1. **TMDS_PLLVR**:
   * Xung nhịp đầu vào: `l_clk` ($27\text{ MHz}$).
   * `serial_clk`: $371.25\text{ MHz}$ (dành cho bộ Serializer của HDMI DVI_TX).
   * `clkout_ck`: $12.375\text{ MHz}$ (cung cấp `XCLK` cho cảm biến OV2640).
2. **CLKDIV**:
   * Chia tần số `serial_clk` với hệ số `DIV_MODE = 5` để tạo ra xung nhịp điểm ảnh `pix_clk` ($74.25\text{ MHz}$).
3. **GW_PLLVR**:
   * Xung nhịp đầu vào: `l_clk` ($27\text{ MHz}$).
   * `memory_clk`: $159\text{ MHz}$ (cung cấp xung hoạt động cho bộ đệm HyperRAM Interface).

### Reset Strategy
* Khối **Reset_Sync**: Nhận tín hiệu reset cứng bên ngoài (`ext_reset`) kết hợp với trạng thái khóa pha của các PLL (`pll_lock`) để tạo ra tín hiệu reset hệ thống đồng bộ `sys_resetn`.
* Các tín hiệu reset được phân phối có hệ thống tới từng module để đảm bảo trạng thái khởi tạo an toàn toàn hệ thống trước khi bắt đầu luồng truyền dữ liệu video thời gian thực.
