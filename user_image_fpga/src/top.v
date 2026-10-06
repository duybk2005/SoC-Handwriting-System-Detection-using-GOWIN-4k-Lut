// top.v — Phase 1: Camera OV2640 -> Band Buffer -> MCU resize 28x28 -> IMAGE -> HDMI
// ----------------------------------------------------------------------------
// Clock:
//   27 MHz -> PLL -> 126 MHz (clk_5x, HDMI nối tiếp hóa)
//                 -> 63 MHz  (clk_sys: MCU + AHB)
//   126 MHz -> CLKDIV /5 -> 25,2 MHz (clk_pixel: HDMI, SCCB)
//   25,2 MHz / 2 -> 12,6 MHz -> XCLK của camera
//   PIXCLK do camera xuất ra -> khối cam_capture
// ----------------------------------------------------------------------------
module top (
    input  wire       clk_27m,
    output wire       led,

    // Camera OV2640 (DVP)
    inout  wire       cam_sda,
    output wire       cam_scl,
    output wire       cam_xclk,
    input  wire       cam_pclk,
    input  wire       cam_vsync,
    input  wire       cam_href,
    input  wire [9:0] cam_data,

    // HDMI
    output wire       tmds_clk_n,
    output wire       tmds_clk_p,
    output wire [2:0] tmds_d_n,
    output wire [2:0] tmds_d_p
);

// ---------------------------------------------------------------------------
// Clock + reset
// ---------------------------------------------------------------------------
wire clk_5x;        // 126 MHz
wire clk_sys;       // 63 MHz
wire clk_pixel;     // 25,2 MHz
wire pll_lock;

Gowin_PLLVR u_pll (
    .clkout  (clk_5x),
    .clkoutd (clk_sys),
    .lock    (pll_lock),
    .clkin   (clk_27m)
);

Gowin_CLKDIV u_clkdiv (
    .clkout (clk_pixel),
    .hclkin (clk_5x),
    .resetn (pll_lock)
);

wire sys_resetn = pll_lock;

// XCLK 12,6 MHz cho camera
reg xclk_r = 1'b0;
always @(posedge clk_pixel)
    xclk_r <= ~xclk_r;
assign cam_xclk = xclk_r;

// ---------------------------------------------------------------------------
// Cấu hình camera qua SCCB
// Giữ resend = 1 khoảng 42 ms sau khi PLL khóa để camera ổn định nguồn/clock,
// sau đó gửi bảng thanh ghi một lần.
// ---------------------------------------------------------------------------
reg [20:0] cfg_wait = 21'd0;
always @(posedge clk_pixel or negedge pll_lock)
    if (!pll_lock)            cfg_wait <= 21'd0;
    else if (!cfg_wait[20])   cfg_wait <= cfg_wait + 21'd1;

wire cam_cfg_done;

OV2640_Controller u_cam_cfg (
    .clk             (clk_pixel),
    .resend          (~cfg_wait[20]),
    .config_finished (cam_cfg_done),
    .sioc            (cam_scl),
    .siod            (cam_sda),
    .reset           (),
    .pwdn            ()
);

// ---------------------------------------------------------------------------
// Khối Camera (miền PIXCLK)
// ---------------------------------------------------------------------------
wire        band_we;
wire [6:0]  band_waddr;
wire [31:0] band_wdata;
wire        cam_done_tgl;
wire [15:0] cam_width, cam_lines;
wire        cmd_frame_tgl, cmd_band_tgl;

cam_capture u_cam (
    .pclk          (cam_pclk),
    .rst_n         (sys_resetn),
    .vsync         (cam_vsync),
    .href          (cam_href),
    .pixdata       (cam_data),
    .cmd_frame_tgl (cmd_frame_tgl),
    .cmd_band_tgl  (cmd_band_tgl),
    .band_we       (band_we),
    .band_waddr    (band_waddr),
    .band_wdata    (band_wdata),
    .done_tgl      (cam_done_tgl),
    .dbg_width     (cam_width),
    .dbg_lines     (cam_lines)
);

// ---------------------------------------------------------------------------
// AHB slave
// ---------------------------------------------------------------------------
wire [31:0] m_haddr, m_hwdata, m_hrdata;
wire [1:0]  m_htrans;
wire        m_hsel, m_hwrite, m_hreadyout, m_hresp;

wire [9:0]  img_raddr;
wire [7:0]  img_rdata;

// MAC <-> bộ nhớ
wire         mac_busy;
wire [11:0]  mac_paddr;
wire [31:0]  mac_pdata;
wire         res_we;
wire [4:0]   res_idx;
wire [31:0]  res_data;
wire         mac_start_tgl, mac_layer, mac_done_tgl;
wire [7:0]   test_reg;
wire [3:0]   digit;

ahb_band_buf u_slave (
    .clk           (clk_sys),
    .rst_n         (sys_resetn),
    .hsel          (m_hsel),
    .haddr         (m_haddr),
    .htrans        (m_htrans),
    .hwrite        (m_hwrite),
    .hwdata        (m_hwdata),
    .hrdata        (m_hrdata),
    .hreadyout     (m_hreadyout),
    .hresp         (m_hresp),
    .led           (led),
    .test_reg      (test_reg),
    .digit         (digit),
    .band_wclk     (cam_pclk),
    .band_we       (band_we),
    .band_waddr    (band_waddr),
    .band_wdata    (band_wdata),
    .cmd_frame_tgl (cmd_frame_tgl),
    .cmd_band_tgl  (cmd_band_tgl),
    .cam_done_tgl  (cam_done_tgl),
    .cam_cfg_done  (cam_cfg_done),
    .cam_width     (cam_width),
    .cam_lines     (cam_lines),
    .img_rclk      (clk_pixel),
    .img_raddr     (img_raddr),
    .img_rdata     (img_rdata),
    .mac_busy_in   (mac_busy),
    .mac_paddr     (mac_paddr),
    .mac_pdata     (mac_pdata),
    .res_we        (res_we),
    .res_idx       (res_idx),
    .res_data      (res_data),
    .mac_start_tgl (mac_start_tgl),
    .mac_layer     (mac_layer),
    .mac_done_tgl  (mac_done_tgl)
);

// ---------------------------------------------------------------------------
// Khối MAC FC1/FC2 (miền clk_sys)
// ---------------------------------------------------------------------------
mac_fc u_mac (
    .clk       (clk_sys),
    .rst_n     (sys_resetn),
    .start_tgl (mac_start_tgl),
    .layer     (mac_layer),
    .done_tgl  (mac_done_tgl),
    .busy      (mac_busy),
    .p_addr    (mac_paddr),
    .p_rdata   (mac_pdata),
    .res_we    (res_we),
    .res_idx   (res_idx),
    .res_data  (res_data)
);

// ---------------------------------------------------------------------------
// Hard core Cortex-M3
// ---------------------------------------------------------------------------
mcu u_mcu (
    .sys_clk          (clk_sys),
    .master_hclk      (),
    .master_hrst      (),
    .master_hsel      (m_hsel),
    .master_haddr     (m_haddr),
    .master_htrans    (m_htrans),
    .master_hwrite    (m_hwrite),
    .master_hsize     (),
    .master_hburst    (),
    .master_hprot     (),
    .master_hmemattr  (),
    .master_hexreq    (),
    .master_hmaster   (),
    .master_hwdata    (m_hwdata),
    .master_hmastlock (),
    .master_hreadymux (),
    .master_hauser    (),
    .master_hwuser    (),
    .master_hrdata    (m_hrdata),
    .master_hreadyout (m_hreadyout),
    .master_hresp     (m_hresp),
    .master_hexresp   (1'b0),
    .master_hruser    (3'b000),

    // cổng slave của MCU (FPGA làm master) không dùng
    .slave_hsel       (1'b0),
    .slave_haddr      (32'd0),
    .slave_htrans     (2'b00),
    .slave_hwrite     (1'b0),
    .slave_hsize      (3'b010),
    .slave_hburst     (3'b000),
    .slave_hprot      (4'b0011),
    .slave_hmemattr   (2'b00),
    .slave_hexreq     (1'b0),
    .slave_hmaster    (4'b0000),
    .slave_hwdata     (32'd0),
    .slave_hmastlock  (1'b0),
    .slave_hauser     (1'b0),
    .slave_hwuser     (4'b0000),
    .slave_hrdata     (),
    .slave_hready     (),
    .slave_hresp      (),
    .slave_hexresp    (),
    .slave_hruser     (),

    .reset_n          (sys_resetn)
);

// ---------------------------------------------------------------------------
// DEBUG: 8 ô trạng thái hiện trên HDMI (trái -> phải = bit 0 -> 7)
//   0: luôn 1          -> HDMI chạy (ô tham chiếu)
//   1: cam_cfg_done    -> SCCB đã gửi xong bảng thanh ghi
//   2: PCLK hoạt động  -> nháy nếu camera xuất PIXCLK
//   3: VSYNC hoạt động -> nháy ~1 Hz nếu camera ra frame
//   4: width == 640    -> số pixel/hàng đúng
//   5: lines 460..500  -> số hàng/frame đúng
//   6: LED của MCU    -> nháy mỗi frame MCU xử lý xong
//   7: done_tgl        -> nháy mỗi khi Camera ghi xong 1 band
// ---------------------------------------------------------------------------
reg [22:0] pclk_cnt = 23'd0;
reg [5:0]  vs_cnt   = 6'd0;
reg [1:0]  vs_p     = 2'b00;
reg        w_ok     = 1'b0;
reg        l_ok     = 1'b0;
always @(posedge cam_pclk) begin
    pclk_cnt <= pclk_cnt + 23'd1;
    vs_p     <= {vs_p[0], cam_vsync};
    if (vs_p[1] ^ vs_p[0]) vs_cnt <= vs_cnt + 6'd1;
    w_ok <= (cam_width == 16'd640);
    l_ok <= (cam_lines >= 16'd460) && (cam_lines <= 16'd500);
end

wire [7:0] dbg_raw = {cam_done_tgl, led, l_ok, w_ok, vs_cnt[5], pclk_cnt[22], cam_cfg_done, 1'b1};
reg  [7:0] dbg_s1, dbg_s2, dbg2_s1, dbg2_s2;
always @(posedge clk_pixel) begin
    dbg_s1  <= dbg_raw;
    dbg_s2  <= dbg_s1;
    dbg2_s1 <= test_reg;
    dbg2_s2 <= dbg2_s1;
end

// ---------------------------------------------------------------------------
// HDMI 640x480: hiện ảnh IMAGE 28x28, phóng 8 lần (224x224) ở giữa màn hình
// ---------------------------------------------------------------------------
wire hdmi_resetn;

Reset_Sync u_hdmi_rst (
    .clk       (clk_pixel),
    .ext_reset (pll_lock),
    .resetn    (hdmi_resetn)
);

svo_hdmi #(
    .SVO_MODE           ("640x480V"),
    .SVO_FRAMERATE      (60),
    .SVO_BITS_PER_PIXEL (24),
    .SVO_BITS_PER_RED   (8),
    .SVO_BITS_PER_GREEN (8),
    .SVO_BITS_PER_BLUE  (8),
    .SVO_BITS_PER_ALPHA (0)
) u_hdmi (
    .clk          (clk_pixel),
    .resetn       (hdmi_resetn),
    .clk_pixel    (clk_pixel),
    .clk_5x_pixel (clk_5x),
    .locked       (pll_lock),
    .img_raddr    (img_raddr),
    .img_rdata    (img_rdata),
    .dbg          (dbg_s2),
    .dbg2         (dbg2_s2),
    .img_busy     (),
    .digit        (digit),
    .tmds_clk_n   (tmds_clk_n),
    .tmds_clk_p   (tmds_clk_p),
    .tmds_d_n     (tmds_d_n),
    .tmds_d_p     (tmds_d_p)
);

endmodule

// ---------------------------------------------------------------------------
module Reset_Sync (
    input  wire clk,
    input  wire ext_reset,
    output wire resetn
);
    reg [3:0] cnt = 4'b0;
    always @(posedge clk or negedge ext_reset)
        if (!ext_reset) cnt <= 4'b0;
        else            cnt <= cnt + !resetn;
    assign resetn = &cnt;
endmodule
