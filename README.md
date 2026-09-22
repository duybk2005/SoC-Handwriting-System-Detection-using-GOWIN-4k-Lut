# SoC-Handwriting-System-Detection-using-GOWIN-4k-Lut
Project of Specital Topics for IC Design (HCMUT)

I. MỤC TIÊU BÀI TẬP (PROJECT OBJECTIVES)

- Cấu hình và tích hợp các khối IP Core của Gowin (HyperRAM_Memory_Interface_Top, GW_PLLVR, TMDS_PLLVR, CLKDIV) trên chip FPGA GW1NSR-4C.
- Thu nhận luồng ảnh từ cảm biến OV2640 qua giao tiếp DVP, lưu tạm vào hệ thống HyperRAM/PSRAM, và xuất hình ảnh ra cổng HDMI ở độ phân giải 1280x720 (720p).
- Đóng gói khối chọn luồng dữ liệu (Switch giữa Pattern Test và Camera Real-time) bằng nút nhấn key.

II. KIẾN TRÚC TỔNG QUAN HỆ THỐNG (video_top)
Sơ đồ khối luồng dữ liệu dựa trên code Verilog thực tế:
<img width="1024" height="559" alt="image" src="https://github.com/user-attachments/assets/718e1d6f-2254-46a2-b5d6-a0a18ad54cc2" />

III. PHÂN TÍCH CHI TIẾT CÁC MODULE TRONG CODE
1. Khối Đồng bộ & Tạo Xung Clock (Clock Management & Reset)
- Reset_Sync: Khối chống hiện tượng Metastability khi giải phóng tín hiệu Reset hệ thống (sys_resetn).
- TMDS_PLLVR: Tạo xung serial_clk cho giao tiếp TMDS HDMI từ xung đầu vào I_clk (27MHz) và chia nhỏ ra xung clk_12M để cấp làm xung XCLK cho cảm biến camera OV2640.
- CLKDIV: Chia tần số serial_clk cho 5 (DIV_MODE=5) để thu được xung pix_clk phục vụ quét ảnh HDMI.
- GW_PLLVR: Nhánh PLL chuyên biệt tạo xung memory_clk đáp ứng băng thông truy xuất cho HyperRAM.

2. Khối Cấu hình & Thu nhận Dữ liệu Camera (OV2640_Controller)
- Khai báo giao tiếp SCCB (SCL, SDA) tương tự I2C để khởi tạo thanh ghi cho camera OV2640.
- Nhận dữ liệu bus PIXDATA[9:0], xung PIXCLK, tín hiệu đồng bộ VSYNC và HREF.
- Chuyển đổi dữ liệu byte thu được thành định dạng điểm ảnh RGB565 (cam_data).

3. Khối Chuyển đổi Chế độ (key_flag & MUX)
- Module key_flag thực hiện khử dải phím (Debounce 20ms) từ nút bấm key.
- MUX dữ liệu chuyển đổi giữa 2 nguồn:
+ Chế độ 1 (Test Pattern): Lấy dữ liệu màu tổng hợp từ module testpattern.
+ Chế độ 2 (Camera Live): Lấy luồng dữ liệu pixel thực từ cảm biến OV2640.

4. Khối Bộ Nhớ Đệm Khung Hình (Video Frame Buffer & HyperRAM)
- Video_Frame_Buffer_Top: Quản lý ghi/đọc dữ liệu theo cơ chế FIFO đệm, tránh hiện tượng xé hình (Tearing).
- HyperRAM_Memory_Interface_Top: Khối IP Core vật lý điều khiển thanh HyperRAM trên Tang Nano 4K qua bus 8-bit vi sai (IO_hpram_dq, IO_hpram_rwds, O_hpram_ck).
- Chờ tín hiệu hiệu chuẩn init_calib kéo lên mức high mới cho phép luồng ghi đọc bộ nhớ hoạt động.

5. Khối Đồng bộ Video & Mã hóa HDMI (syn_gen & DVI_TX_Top)
- syn_gen: Khởi tạo các tín hiệu định thời gian quét hình (Hor/Ver Active, Back Porch, Front Porch, Sync) chuẩn 720p/VGA.
- DVI_TX_Top: Mã hóa màu 24-bit RGB (rgb_data) cùng tín hiệu đồng bộ thành các luồng TMDS vi sai (O_tmds_clk_p/n, O_tmds_data_p/n[2:0]) xuất ra jack HDMI.

IV. TỔNG HỢP IP CORE VÀ RÀNG BUỘC CHÂN (PIN CONSTRAINTS)
1. Danh sách IP Core của Gowin đã sử dụng:
- GW_PLLVR: PLL tạo xung cho HyperRAM.
- HyperRAM_Memory_Interface_Top: Bộ điều khiển RAM tĩnh (PSRAM/HyperRAM).
- TMDS_PLLVR: PLL tạo xung tốc độ cao cho HDMI.
- CLKDIV: Bộ chia tần số xung clock.
- DVI_TX_Top: IP Encoder xuất tín hiệu vi sai TMDS HDMI.

2. Sơ đồ gán chân tiêu biểu (Tang Nano 4K - GW1NSR-4C)
- Input Clock: I_clk (Pin 45 - 27MHz).
- HDMI Output: O_tmds_clk_p (Pins 28,27), O_tmds_data_p (Pins 30,29 / 32,31 / 35,34).
- Camera DVP: PIXCLK (Pin 41), VSYNC (Pin 43), HREF (Pin 42), Bus Data PIXDATA[9:0].
- System Indicator: O_led[0] (Báo trạng thái hoạt động), O_led[1] (Báo trạng thái Calib HyperRAM).
