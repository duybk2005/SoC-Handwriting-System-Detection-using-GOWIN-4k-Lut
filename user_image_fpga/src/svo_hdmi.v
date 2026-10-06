/*
 * svo_hdmi.v - Modified from sipeed HDMI reference
 * Thay svo_tcard bang pixel generator doc tu Image SRAM 28x28
 * Scale 8x len 224x224, hien giua man hinh 640x480
 */

`timescale 1ns / 1ps
`include "hdmi/svo_defines.vh"

module svo_hdmi(
    input clk,
    input resetn,

    // video clocks
    input clk_pixel,
    input clk_5x_pixel,
    input locked,

    // Image SRAM read port (28x28 gray, 1 cycle latency)
    output reg  [9:0]  img_raddr,
    input  wire [7:0]  img_rdata,

    // 8 bit trạng thái debug (đã đồng bộ về clk_pixel), hiện thành 8 ô ở góc trên
    input  wire [7:0]  dbg,
    // hàng ô thứ 2: kết quả tự kiểm tra của MCU (thanh ghi TEST)
    input  wire [7:0]  dbg2,
    // = 1 khi HDMI đang dùng cổng đọc IMAGE (MAC phải chờ)
    output wire        img_busy,
    // kết quả nhận dạng (thanh ghi Digit, miền clk_sys): 0..9, giá trị khác -> gạch ngang
    input  wire [3:0]  digit,

    // output signals
    output       tmds_clk_n,
    output       tmds_clk_p,
    output [2:0] tmds_d_n,
    output [2:0] tmds_d_p
);
    parameter SVO_MODE             =   "640x480V";
    parameter SVO_FRAMERATE        =   60;
    parameter SVO_BITS_PER_PIXEL   =   24;
    parameter SVO_BITS_PER_RED     =    8;
    parameter SVO_BITS_PER_GREEN   =    8;
    parameter SVO_BITS_PER_BLUE    =    8;
    parameter SVO_BITS_PER_ALPHA   =    0;

    `SVO_DECLS

    // ── Image display parameters ──
    // 28x28 gray, scale 8x = 224x224, centered in 640x480
    localparam IMG_W    = 28;
    localparam SCALE    = 8;
    localparam DISP_W   = 224;  // 28*8
    localparam DISP_H   = 224;  // 28*8
    localparam X_OFFSET = (SVO_HOR_PIXELS - DISP_W) / 2;  // 208
    localparam Y_OFFSET = (SVO_VER_PIXELS - DISP_H) / 2;  // 128

    // ── Reset sync (copy y het reference) ──
    reg [3:0] locked_clk_q;
    reg [3:0] resetn_clk_pixel_q;

    always @(posedge clk)
        locked_clk_q <= {locked_clk_q, locked};

    always @(posedge clk_pixel)
        resetn_clk_pixel_q <= {resetn_clk_pixel_q, resetn};

    wire clk_resetn       = resetn && locked_clk_q[3];
    wire clk_pixel_resetn = locked && resetn_clk_pixel_q[3];

    // ── Pixel generator (thay cho svo_tcard) ──
    // Dung AXIS stream giong het svo_tcard
    reg out_axis_tvalid;
    wire out_axis_tready;
    reg [SVO_BITS_PER_PIXEL-1:0] out_axis_tdata;
    reg [0:0] out_axis_tuser;

    reg [`SVO_XYBITS-1:0] hcursor;
    reg [`SVO_XYBITS-1:0] vcursor;

    // BSRAM read: address stage → data available next cycle
    // Pre-fetch: tinh addr 1 cycle truoc khi can data
    wire [`SVO_XYBITS-1:0] hcursor_next = (hcursor == SVO_HOR_PIXELS-1) ? 0 : hcursor + 1;
    wire [`SVO_XYBITS-1:0] vcursor_next = (hcursor == SVO_HOR_PIXELS-1) ?
                                           ((vcursor == SVO_VER_PIXELS-1) ? 0 : vcursor + 1) :
                                           vcursor;

    wire in_img_next = (hcursor_next >= X_OFFSET) && (hcursor_next < X_OFFSET + DISP_W)
                    && (vcursor_next >= Y_OFFSET) && (vcursor_next < Y_OFFSET + DISP_H);

    // SCALE=8=2^3 → use arithmetic right shift instead of division (saves ~100 LUT)
    wire [4:0] img_x_next = (hcursor_next - X_OFFSET[`SVO_XYBITS-1:0]) >> 3;
    wire [4:0] img_y_next = (vcursor_next - Y_OFFSET[`SVO_XYBITS-1:0]) >> 3;

    reg in_img_d;  // delayed 1 cycle cho BSRAM latency

    // ── Overlay debug (tính theo pixel hiện tại hcursor/vcursor) ──
    // Viền trắng 4 px quanh vùng ảnh 224x224
    wire in_frame = (hcursor >= X_OFFSET - 4) && (hcursor < X_OFFSET + DISP_W + 4)
                 && (vcursor >= Y_OFFSET - 4) && (vcursor < Y_OFFSET + DISP_H + 4);
    // ── Banner "Group 1 - L01" ở vị trí top màn hình ──
    localparam BAN_X0 = 216; // Căn giữa trên màn hình 640x480: (640 - 208) / 2 = 216
    localparam BAN_Y0 = 36;  // Vị trí phía trên ảnh (ảnh bắt đầu từ Y=128)
    localparam BAN_W  = 208; // 13 ký tự x 16 px (font 8x16 scale 2x)
    localparam BAN_H  = 32;  // 16 px x 2

    wire in_banner = (hcursor >= BAN_X0) && (hcursor < BAN_X0 + BAN_W)
                  && (vcursor >= BAN_Y0) && (vcursor < BAN_Y0 + BAN_H);

    wire in_ban_panel = (hcursor >= BAN_X0 - 12) && (hcursor < BAN_X0 + BAN_W + 12)
                     && (vcursor >= BAN_Y0 - 8)  && (vcursor < BAN_Y0 + BAN_H + 8);

    wire in_ban_border = in_ban_panel &&
                        ((hcursor < BAN_X0 - 10) || (hcursor >= BAN_X0 + BAN_W + 10) ||
                         (vcursor < BAN_Y0 - 6)  || (vcursor >= BAN_Y0 + BAN_H + 6));

    wire [3:0] c_idx = (hcursor - BAN_X0) >> 4;              // 0..12
    wire [2:0] c_x   = ((hcursor - BAN_X0) >> 1) & 3'b111;   // 0..7
    wire [3:0] c_y   = ((vcursor - BAN_Y0) >> 1) & 4'b1111;  // 0..15

    reg [7:0] font_row;
    always @(*) begin
        case (c_idx)
            4'd0: begin // 'G'
                case (c_y)
                    4'd2:  font_row = 8'h3C;
                    4'd3:  font_row = 8'h66;
                    4'd4, 4'd5, 4'd6: font_row = 8'hC0;
                    4'd7:  font_row = 8'hCE;
                    4'd8, 4'd9: font_row = 8'hC6;
                    4'd10: font_row = 8'h66;
                    4'd11: font_row = 8'h3C;
                    default: font_row = 8'h00;
                endcase
            end
            4'd1: begin // 'r'
                case (c_y)
                    4'd6:  font_row = 8'h6C;
                    4'd7:  font_row = 8'h76;
                    4'd8, 4'd9, 4'd10, 4'd11: font_row = 8'h60;
                    default: font_row = 8'h00;
                endcase
            end
            4'd2: begin // 'o'
                case (c_y)
                    4'd6:  font_row = 8'h3C;
                    4'd7, 4'd8, 4'd9, 4'd10: font_row = 8'h66;
                    4'd11: font_row = 8'h3C;
                    default: font_row = 8'h00;
                endcase
            end
            4'd3: begin // 'u'
                case (c_y)
                    4'd6, 4'd7, 4'd8, 4'd9, 4'd10: font_row = 8'h66;
                    4'd11: font_row = 8'h3E;
                    default: font_row = 8'h00;
                endcase
            end
            4'd4: begin // 'p'
                case (c_y)
                    4'd6:  font_row = 8'h6C;
                    4'd7:  font_row = 8'h72;
                    4'd8, 4'd9: font_row = 8'h66;
                    4'd10: font_row = 8'h72;
                    4'd11: font_row = 8'h6C;
                    4'd12, 4'd13: font_row = 8'h60;
                    4'd14: font_row = 8'hF0;
                    default: font_row = 8'h00;
                endcase
            end
            4'd6, 4'd12: begin // '1'
                case (c_y)
                    4'd3:  font_row = 8'h18;
                    4'd4:  font_row = 8'h38;
                    4'd5:  font_row = 8'h78;
                    4'd6, 4'd7, 4'd8, 4'd9, 4'd10: font_row = 8'h18;
                    4'd11: font_row = 8'h7E;
                    default: font_row = 8'h00;
                endcase
            end
            4'd8: begin // '-'
                case (c_y)
                    4'd7, 4'd8: font_row = 8'h7E;
                    default: font_row = 8'h00;
                endcase
            end
            4'd10: begin // 'L'
                case (c_y)
                    4'd3, 4'd4, 4'd5, 4'd6, 4'd7, 4'd8, 4'd9: font_row = 8'h60;
                    4'd10: font_row = 8'h62;
                    4'd11: font_row = 8'h7E;
                    default: font_row = 8'h00;
                endcase
            end
            4'd11: begin // '0'
                case (c_y)
                    4'd3:  font_row = 8'h3C;
                    4'd4:  font_row = 8'h66;
                    4'd5, 4'd6, 4'd7, 4'd8, 4'd9: font_row = 8'hC3;
                    4'd10: font_row = 8'h66;
                    4'd11: font_row = 8'h3C;
                    default: font_row = 8'h00;
                endcase
            end
            default: font_row = 8'h00; // spaces (4'd5, 4'd7, 4'd9) and other
        endcase
    end

    wire ban_on = in_banner && font_row[3'd7 - c_x];

    // Chữ số kết quả, kiểu LED 7 đoạn, đặt bên phải ảnh (ảnh chiếm x 208..431, y 128..351)
    wire dig_panel, dig_on;
    digit_7seg #(
        .XB (`SVO_XYBITS),
        .X0 (492), .Y0 (160), .W (96), .H (160), .T (18), .M (16)
    ) u_digit (
        .clk     (clk_pixel),
        .digit   (digit),
        .hcursor (hcursor),
        .vcursor (vcursor),
        .panel   (dig_panel),
        .on      (dig_on)
    );

    assign img_busy = in_img_d;

    always @(posedge clk_pixel) begin
        if (!clk_pixel_resetn) begin
            img_raddr <= 0;
            in_img_d  <= 0;
        end else if (!out_axis_tvalid || out_axis_tready) begin
            // Setup SRAM read address 1 cycle truoc
            if (in_img_next)
                img_raddr <= img_y_next * IMG_W + img_x_next;
            else
                img_raddr <= 0;
            in_img_d <= in_img_next;
        end
    end

    always @(posedge clk_pixel) begin
        if (!clk_pixel_resetn) begin
            hcursor       <= 0;
            vcursor       <= 0;
            out_axis_tvalid <= 0;
            out_axis_tdata  <= 0;
            out_axis_tuser  <= 0;
        end else if (!out_axis_tvalid || out_axis_tready) begin
            out_axis_tvalid <= 1;
            out_axis_tuser[0] <= (!hcursor && !vcursor);

            // Doc tu Image SRAM (28x28 gray, scale 8x)
            // Gray → BGR: {gray, gray, gray} dung cho ca 2 format
            // Thứ tự kênh: [23:16] = Blue, [15:8] = Green, [7:0] = Red
            if (in_img_d)
                out_axis_tdata <= {img_rdata, img_rdata, img_rdata};
            else if (ban_on)
                out_axis_tdata <= 24'hFFFFFF;  // Chữ 'Group 1 - L01' màu trắng
            else if (in_ban_panel)
                out_axis_tdata <= in_ban_border ? 24'h00FFFF : 24'h000000; // Panel đen, viền cyan
            else if (dig_on)
                out_axis_tdata <= 24'hFFFFFF;  // đoạn sáng: trắng
            else if (dig_panel)
                out_axis_tdata <= 24'h000000;  // nền khung chữ số: đen
            else if (in_frame)
                out_axis_tdata <= 24'hFFFFFF;  // viền trắng
            else
                out_axis_tdata <= 24'h602000;  // nền xanh dương

            // Advance cursor
            if (hcursor == SVO_HOR_PIXELS - 1) begin
                hcursor <= 0;
                vcursor <= (vcursor == SVO_VER_PIXELS - 1) ? 0 : vcursor + 1;
            end else begin
                hcursor <= hcursor + 1;
            end
        end
    end

    // ── Video Encoder ──
    wire video_enc_tvalid, video_enc_tready;
    wire [SVO_BITS_PER_PIXEL-1:0] video_enc_tdata;
    wire [3:0] video_enc_tuser;

    svo_enc #( `SVO_PASS_PARAMS ) svo_enc (
        .clk(clk_pixel),
        .resetn(clk_pixel_resetn),
        .in_axis_tvalid(out_axis_tvalid),
        .in_axis_tready(out_axis_tready),
        .in_axis_tdata(out_axis_tdata),
        .in_axis_tuser(out_axis_tuser),
        .out_axis_tvalid(video_enc_tvalid),
        .out_axis_tready(video_enc_tready),
        .out_axis_tdata(video_enc_tdata),
        .out_axis_tuser(video_enc_tuser)
    );

    assign video_enc_tready = 1;

    // ── TMDS Encoders ──
    wire [2:0] tmds_d;
    wire [2:0] tmds_d0, tmds_d1, tmds_d2, tmds_d3, tmds_d4;
    wire [2:0] tmds_d5, tmds_d6, tmds_d7, tmds_d8, tmds_d9;

    svo_tmds svo_tmds_0 (
        .clk(clk_pixel), .resetn(clk_pixel_resetn),
        .de(!video_enc_tuser[3]),
        .ctrl(video_enc_tuser[2:1]),
        .din(video_enc_tdata[23:16]),
        .dout({tmds_d9[0], tmds_d8[0], tmds_d7[0], tmds_d6[0], tmds_d5[0],
               tmds_d4[0], tmds_d3[0], tmds_d2[0], tmds_d1[0], tmds_d0[0]})
    );
    svo_tmds svo_tmds_1 (
        .clk(clk_pixel), .resetn(clk_pixel_resetn),
        .de(!video_enc_tuser[3]),
        .ctrl(2'b0),
        .din(video_enc_tdata[15:8]),
        .dout({tmds_d9[1], tmds_d8[1], tmds_d7[1], tmds_d6[1], tmds_d5[1],
               tmds_d4[1], tmds_d3[1], tmds_d2[1], tmds_d1[1], tmds_d0[1]})
    );
    svo_tmds svo_tmds_2 (
        .clk(clk_pixel), .resetn(clk_pixel_resetn),
        .de(!video_enc_tuser[3]),
        .ctrl(2'b0),
        .din(video_enc_tdata[7:0]),
        .dout({tmds_d9[2], tmds_d8[2], tmds_d7[2], tmds_d6[2], tmds_d5[2],
               tmds_d4[2], tmds_d3[2], tmds_d2[2], tmds_d1[2], tmds_d0[2]})
    );

    // ── Serializer ──
    OSER10 tmds_serdes [2:0] (
        .Q(tmds_d),
        .D0(tmds_d0), .D1(tmds_d1), .D2(tmds_d2), .D3(tmds_d3), .D4(tmds_d4),
        .D5(tmds_d5), .D6(tmds_d6), .D7(tmds_d7), .D8(tmds_d8), .D9(tmds_d9),
        .PCLK(clk_pixel),
        .FCLK(clk_5x_pixel),
        .RESET(~clk_pixel_resetn)
    );

    // ── LVDS Buffers ──
    ELVDS_OBUF tmds_bufds [3:0] (
        .I({clk_pixel, tmds_d}),
        .O({tmds_clk_p, tmds_d_p}),
        .OB({tmds_clk_n, tmds_d_n})
    );

endmodule
