// ahb_band_buf.v — AHB slave: SRAM FPGA theo SRAM_FPGA_mapping.xlsx (v2) + thanh ghi
// ----------------------------------------------------------------------------
// Địa chỉ AHB = 0xA0000000 + offset (địa chỉ logic MCU thấy):
//
//  Offset          R/W  Vùng               Nằm ở
//  0x0000-0x030F   RW   image[784]         ghi: IMAGE RAM (HDMI đọc) + bản sao trong PARAM RAM (MAC đọc); đọc: bản sao
//  0x0310-0x034F   R    Acc1[16]  INT32    PARAM RAM (MAC ghi)
//  0x0350-0x035F   RW   Hidden[16] INT8    PARAM RAM (MCU ghi, MAC đọc khi chạy FC2)
//  0x0360-0x0387   R    Logit[10] INT32    PARAM RAM (MAC ghi)
//  0x0388          RW   Digit              thanh ghi (bit 3:0): 0..9 = kết quả, 14 = 'E' (không đủ tự tin), 15 = chưa có / khung trống (gạch ngang)
//  0x0400-0x070F   RW   NET image[784]     CHỈ bản sao trong PARAM RAM (đầu vào MAC), không ghi IMAGE RAM của HDMI.
//                                          Dùng để HDMI hiện ảnh camera thật, còn mạng nhận ảnh đã chuẩn hoá kiểu MNIST.
//  0x0800-0x3FFF   RW   PARAM: W1 0x0800, W2 0x3900, B1 0x39A0, B2 0x39E0
//  0x4000-0x41BF   R    Band 4x112         PARAM RAM (camera ghi)
//  0x4800          W    CTRL   : bit0 band tiếp theo, bit1 frame mới, bit2 MAC start, bit3 MAC layer (0 FC1, 1 FC2)
//  0x4804          R    STATUS : bit0 camera busy, bit1 band done, bit2 camera cấu hình xong,
//                                bit3 MAC busy, bit4 MAC done
//  0x4808          RW   LED    : bit0
//  0x480C          R    DBG    : [15:0] pixel/hàng, [31:16] hàng/frame
//  0x4810          RW   TEST   : 8 bit kết quả tự kiểm tra của MCU (hàng ô thứ 2 trên HDMI)
//
// Khối vật lý (BSRAM, MCU dùng 2 khối, còn 8 khối):
//  IMAGE RAM : 1 khối. Ghi clk_sys (AHB), đọc clk_pixel (HDMI).
//  PARAM RAM : 7 khối x 512 word, đọc + ghi đều ở clk_sys. Word tương đối rel (0 = offset 0x0800):
//      rel    0..3135  W1          rel 3136..3175 W2       rel 3176..3191 B1    rel 3192..3201 B2
//      rel 3204..3399  image copy  rel 3400..3511 Band     rel 3512..3543 Acc1 (0..15) + Logit (16..25)
//      rel 3544..3547  Hidden (4 word, Hidden[j] ở byte j&3 của word j>>2)
//    Cổng đọc : MAC khi MAC chạy, còn lại AHB.
//    Cổng ghi : AHB > MAC > Camera (camera có hàng chờ 1 word, mỗi word camera cách nhau >= 16 PIXCLK).
// ----------------------------------------------------------------------------
module ahb_band_buf (
    input  wire         clk,            // clk_sys
    input  wire         rst_n,

    // AHB-Lite slave
    input  wire         hsel,
    input  wire [31:0]  haddr,
    input  wire [1:0]   htrans,
    input  wire         hwrite,
    input  wire [31:0]  hwdata,
    output reg  [31:0]  hrdata,
    output wire         hreadyout,
    output wire         hresp,

    output reg          led,
    output reg  [7:0]   test_reg,
    output reg  [3:0]   digit,

    // Band Buffer từ khối Camera (miền PIXCLK, giữ nguyên tới lần ghi sau)
    input  wire         band_wclk,
    input  wire         band_we,
    input  wire [6:0]   band_waddr,
    input  wire [31:0]  band_wdata,

    // bắt tay với khối Camera
    output reg          cmd_frame_tgl,
    output reg          cmd_band_tgl,
    input  wire         cam_done_tgl,
    input  wire         cam_cfg_done,
    input  wire [15:0]  cam_width,
    input  wire [15:0]  cam_lines,

    // HDMI đọc IMAGE (miền clk_pixel), byte 0..783
    input  wire         img_rclk,
    input  wire [9:0]   img_raddr,
    output wire [7:0]   img_rdata,

    // MAC (miền clk_sys)
    input  wire         mac_busy_in,
    input  wire [11:0]  mac_paddr,
    output wire [31:0]  mac_pdata,
    input  wire         res_we,
    input  wire [4:0]   res_idx,
    input  wire [31:0]  res_data,
    output reg          mac_start_tgl,
    output reg          mac_layer,
    input  wire         mac_done_tgl
);

localparam [11:0] REL_IMG  = 12'd3204;
localparam [11:0] REL_BAND = 12'd3400;
localparam [11:0] REL_RES  = 12'd3512;
localparam [11:0] REL_HID  = 12'd3544;

assign hreadyout = 1'b1;   // không chèn wait state
assign hresp     = 1'b0;   // luôn OKAY

// ---------------------------------------------------------------------------
// Giải mã địa chỉ (dùng chung cho pha địa chỉ và pha dữ liệu)
// ---------------------------------------------------------------------------
function [12:0] rel_of;            // {hợp lệ, rel[11:0]} của một offset AHB trong PARAM RAM
    input [14:0] a;
    reg   [12:0] w;
    begin
        w = a[14:2];
        if (a[14:11] == 4'b0000) begin                       // vùng DATA
            if (w < 13'd196)                     rel_of = {1'b1, REL_IMG + w[11:0]};
            else if (w >= 13'd196 && w < 13'd212) rel_of = {1'b1, REL_RES + w[11:0] - 12'd196};
            else if (w >= 13'd212 && w < 13'd216) rel_of = {1'b1, REL_HID + w[11:0] - 12'd212};
            else if (w >= 13'd216 && w < 13'd226) rel_of = {1'b1, REL_RES + w[11:0] - 12'd200};
            else if (w >= 13'd256 && w < 13'd452) rel_of = {1'b1, REL_IMG + w[11:0] - 12'd256};   // NET
            else                                 rel_of = 13'd0;
        end else if (a[14] == 1'b0)                          // 0x0800-0x3FFF: PARAM
            rel_of = {1'b1, w[11:0] - 12'd512};
        else if (a[14:11] == 4'b1000)                        // 0x4000-0x47FF: Band
            rel_of = {1'b1, REL_BAND + {5'd0, w[6:0]}};
        else
            rel_of = 13'd0;
    end
endfunction

// ---------------------------------------------------------------------------
// AHB: pha địa chỉ ở chu kỳ N, pha dữ liệu ở chu kỳ N+1
// ---------------------------------------------------------------------------
reg        sel_ph, wr_ph;
reg [14:0] addr_ph;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        sel_ph <= 1'b0; wr_ph <= 1'b0; addr_ph <= 15'd0;
    end else begin
        sel_ph  <= hsel & htrans[1];
        wr_ph   <= hwrite;
        addr_ph <= haddr[14:0];
    end
end

wire        wr       = sel_ph & wr_ph;
wire [12:0] w_ph     = addr_ph[14:2];
wire [12:0] rel_ph   = rel_of(addr_ph);
wire [12:0] rel_ad   = rel_of(haddr[14:0]);
wire        r_data   = (addr_ph[14:11] == 4'b0000);
wire        r_reg    = (addr_ph[14:11] == 4'b1001);
wire        d_img    = r_data && (w_ph < 13'd196);
wire        d_digit  = r_data && (w_ph == 13'd226);

// ---------------------------------------------------------------------------
// IMAGE RAM (1 BSRAM): ghi clk_sys, HDMI đọc clk_pixel
// ---------------------------------------------------------------------------
reg [31:0] image_ram [0:195] /* synthesis syn_ramstyle = "block_ram" */;
always @(posedge clk)
    if (wr && d_img) image_ram[w_ph[7:0]] <= hwdata;

reg [31:0] img_word;
reg [1:0]  img_byte;
always @(posedge img_rclk) begin
    img_word <= image_ram[img_raddr[9:2]];
    img_byte <= img_raddr[1:0];
end
assign img_rdata = (img_byte == 2'd0) ? img_word[7:0]   :
                   (img_byte == 2'd1) ? img_word[15:8]  :
                   (img_byte == 2'd2) ? img_word[23:16] : img_word[31:24];

// ---------------------------------------------------------------------------
// Camera -> clk_sys: đổi xung ghi thành toggle ở PIXCLK, đồng bộ sang clk_sys
// ---------------------------------------------------------------------------
reg band_tgl = 1'b0;
always @(posedge band_wclk)
    if (band_we) band_tgl <= ~band_tgl;

reg [2:0]  bw_s;
reg        cam_pend;
reg [6:0]  cam_addr;
reg [31:0] cam_data;

// ---------------------------------------------------------------------------
// PARAM RAM (7 BSRAM x 512 word), 1 cổng ghi + 1 cổng đọc, cùng clk_sys
// ---------------------------------------------------------------------------
wire ahb_pw = wr && rel_ph[12];                 // AHB ghi vào PARAM RAM (kể cả bản sao image)

reg         pw_en;
reg  [11:0] pw_addr;
reg  [31:0] pw_data;
always @(*) begin
    if (ahb_pw) begin
        pw_en = 1'b1; pw_addr = rel_ph[11:0];                 pw_data = hwdata;
    end else if (res_we) begin
        pw_en = 1'b1; pw_addr = REL_RES + {7'd0, res_idx};    pw_data = res_data;
    end else if (cam_pend) begin
        pw_en = 1'b1; pw_addr = REL_BAND + {5'd0, cam_addr};  pw_data = cam_data;
    end else begin
        pw_en = 1'b0; pw_addr = 12'd0;                        pw_data = 32'd0;
    end
end
wire cam_taken = cam_pend && !ahb_pw && !res_we;

wire [11:0] pr_addr = mac_busy_in ? mac_paddr : rel_ad[11:0];
reg  [2:0]  pr_blk_q;
wire [223:0] p_rd;                              // 7 khối x 32 bit

genvar b;
generate for (b = 0; b < 7; b = b + 1) begin : g_param
    reg [31:0] mem [0:511] /* synthesis syn_ramstyle = "block_ram" */;
    reg [31:0] rd;
    always @(posedge clk) begin
        if (pw_en && pw_addr[11:9] == b) mem[pw_addr[8:0]] <= pw_data;
        rd <= mem[pr_addr[8:0]];
    end
    assign p_rd[b*32 +: 32] = rd;
end endgenerate

always @(posedge clk) pr_blk_q <= pr_addr[11:9];
wire [31:0] p_rdata = p_rd[pr_blk_q*32 +: 32];
assign mac_pdata = p_rdata;

// ---------------------------------------------------------------------------
// Đồng bộ tín hiệu về clk_sys
// ---------------------------------------------------------------------------
reg [3:0] done_s;           // thêm 1 tầng để word cuối của band chắc chắn đã ghi xong
reg [2:0] macd_s;
reg [1:0] cfg_s;
always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        done_s <= 4'd0; macd_s <= 3'd0; cfg_s <= 2'd0;
    end else begin
        done_s <= {done_s[2:0], cam_done_tgl};
        macd_s <= {macd_s[1:0], mac_done_tgl};
        cfg_s  <= {cfg_s[0], cam_cfg_done};
    end
end
wire cam_done_pulse = done_s[3] ^ done_s[2];
wire mac_done_pulse = macd_s[2] ^ macd_s[1];

// ---------------------------------------------------------------------------
// Thanh ghi + hàng chờ camera
// ---------------------------------------------------------------------------
reg busy, done, mac_busy, mac_done;

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        busy <= 1'b0; done <= 1'b0; led <= 1'b0;
        cmd_frame_tgl <= 1'b0; cmd_band_tgl <= 1'b0;
        mac_busy <= 1'b0; mac_done <= 1'b0; mac_start_tgl <= 1'b0; mac_layer <= 1'b0;
        test_reg <= 8'd0; digit <= 4'hF;
        bw_s <= 3'd0; cam_pend <= 1'b0; cam_addr <= 7'd0; cam_data <= 32'd0;
    end else begin
        // hàng chờ ghi Band (dữ liệu camera đứng yên >= 16 PIXCLK sau mỗi lần ghi)
        bw_s <= {bw_s[1:0], band_tgl};
        if (bw_s[2] ^ bw_s[1]) begin
            cam_pend <= 1'b1;
            cam_addr <= band_waddr;
            cam_data <= band_wdata;
        end else if (cam_taken)
            cam_pend <= 1'b0;

        if (cam_done_pulse) begin
            busy <= 1'b0;
            done <= 1'b1;
        end
        if (mac_done_pulse) begin
            mac_busy <= 1'b0;
            mac_done <= 1'b1;
        end

        if (wr && d_digit) digit <= hwdata[3:0];

        if (wr && r_reg) begin
            case (addr_ph[4:2])
                3'd0: begin                                  // CTRL
                    if (hwdata[1]) begin
                        cmd_frame_tgl <= ~cmd_frame_tgl;
                        busy <= 1'b1;
                        done <= 1'b0;
                    end else if (hwdata[0]) begin
                        cmd_band_tgl <= ~cmd_band_tgl;
                        busy <= 1'b1;
                        done <= 1'b0;
                    end
                    if (hwdata[2] && !mac_busy) begin
                        mac_layer     <= hwdata[3];
                        mac_start_tgl <= ~mac_start_tgl;
                        mac_busy      <= 1'b1;
                        mac_done      <= 1'b0;
                    end
                end
                3'd2: led      <= hwdata[0];                 // LED
                3'd4: test_reg <= hwdata[7:0];               // TEST
                default: ;
            endcase
        end
    end
end

// ---------------------------------------------------------------------------
// Đọc
// ---------------------------------------------------------------------------
always @(*) begin
    hrdata = 32'd0;
    if (sel_ph && !wr_ph) begin
        if (r_reg) begin
            case (addr_ph[4:2])
                3'd1:    hrdata = {27'd0, mac_done, mac_busy, cfg_s[1], done, busy};
                3'd2:    hrdata = {31'd0, led};
                3'd3:    hrdata = {cam_lines, cam_width};
                3'd4:    hrdata = {24'd0, test_reg};
                default: hrdata = 32'd0;
            endcase
        end else if (d_digit)
            hrdata = {28'd0, digit};
        else if (rel_ph[12])
            hrdata = p_rdata;                                // Band, Acc1, Hidden, Logit, PARAM
    end
end

endmodule
