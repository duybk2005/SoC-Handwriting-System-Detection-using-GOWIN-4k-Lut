// cam_capture.v — Khối Camera: OV2640 (RAW10, 640x480) -> ảnh gray 112x112 -> Band Buffer
// ----------------------------------------------------------------------------
// Chạy toàn bộ ở miền clock PIXCLK của camera.
//
// 1. Đếm tọa độ: x tăng mỗi PIXCLK khi HREF = 1, y tăng khi HREF xuống.
//    Mỗi cạnh của VSYNC (lên hoặc xuống, không cần biết cực tính) -> y = 0.
// 2. Cắt vùng vuông 448x448 ở giữa khung: X0 <= x < X0+448, Y0 <= y < Y0+448.
// 3. Lấy mẫu 1/4 mỗi chiều -> 112x112. Ảnh RAW10 là Bayer (2 pixel cạnh nhau trên
//    một hàng là 2 màu khác nhau), nên mỗi pixel ra = trung bình 2 pixel cạnh nhau
//    (cột 4k và 4k+1) để không bị lệch về một màu.
// 4. Gray = 8 bit cao PIXDATA[9:2]. Ghép 4 pixel thành 1 word, pixel đầu ở bit 7:0.
// 5. Ghi vào Band Buffer: band = 4 hàng ra x 112 pixel = 112 word, địa chỉ r*28 + c.
//
// Bắt tay với MCU (lệnh đến từ miền clk_sys dưới dạng toggle):
//   cmd_frame_tgl : band chờ = 0, cho phép ghi
//   cmd_band_tgl  : cho phép ghi band chờ (MCU đã đọc xong band trước)
//   done_tgl      : đảo mỗi khi ghi xong 1 band
// Chỉ bắt đầu ghi ở đầu band (hàng r = 0). Nếu MCU cho phép trễ khi band đó đang chạy
// qua, khối này chờ tới frame sau mới ghi band đó -> band luôn nguyên vẹn.
// ----------------------------------------------------------------------------
module cam_capture #(
    parameter X0 = 11'd96,      // cột bắt đầu vùng cắt
    parameter Y0 = 11'd16       // hàng bắt đầu vùng cắt
)(
    input  wire        pclk,
    input  wire        rst_n,          // reset không đồng bộ, mức thấp

    // DVP từ camera
    input  wire        vsync,
    input  wire        href,
    input  wire [9:0]  pixdata,

    // lệnh từ MCU (toggle, miền clk_sys)
    input  wire        cmd_frame_tgl,
    input  wire        cmd_band_tgl,

    // ghi Band Buffer
    output reg         band_we,
    output reg  [6:0]  band_waddr,
    output reg  [31:0] band_wdata,
    output reg         done_tgl,

    // debug: kích thước khung camera đo được
    output reg  [15:0] dbg_width,       // số pixel mỗi hàng
    output reg  [15:0] dbg_lines        // số hàng mỗi frame
);

// ---------------------------------------------------------------------------
// Chốt tín hiệu DVP
// ---------------------------------------------------------------------------
reg       vs_r, vs_d, href_r, href_d;
reg [7:0] pix_r;

always @(posedge pclk or negedge rst_n) begin
    if (!rst_n) begin
        vs_r <= 1'b0; vs_d <= 1'b0; href_r <= 1'b0; href_d <= 1'b0; pix_r <= 8'd0;
    end else begin
        vs_r   <= vsync;
        vs_d   <= vs_r;
        href_r <= href;
        href_d <= href_r;
        pix_r  <= pixdata[9:2];
    end
end

wire vs_edge   = vs_r ^ vs_d;
wire href_rise = href_r & ~href_d;
wire href_fall = ~href_r & href_d;

// ---------------------------------------------------------------------------
// Đồng bộ lệnh từ clk_sys (2 FF + phát hiện đổi mức)
// ---------------------------------------------------------------------------
reg [2:0] frame_s, band_s;
always @(posedge pclk or negedge rst_n) begin
    if (!rst_n) begin
        frame_s <= 3'd0; band_s <= 3'd0;
    end else begin
        frame_s <= {frame_s[1:0], cmd_frame_tgl};
        band_s  <= {band_s[1:0],  cmd_band_tgl};
    end
end
wire cmd_frame = frame_s[2] ^ frame_s[1];
wire cmd_band  = band_s[2]  ^ band_s[1];

// ---------------------------------------------------------------------------
// Tọa độ trong khung camera (x là chỉ số của pixel đang nằm ở pix_r)
// ---------------------------------------------------------------------------
reg [10:0] x, y;

always @(posedge pclk or negedge rst_n) begin
    if (!rst_n) begin
        x <= 11'd0; y <= 11'd0; dbg_width <= 16'd0; dbg_lines <= 16'd0;
    end else begin
        if (vs_edge) begin
            if (y != 11'd0) dbg_lines <= {5'd0, y};
            y <= 11'd0;
            x <= 11'd0;
        end else if (href_fall) begin
            dbg_width <= {5'd0, x};
            x <= 11'd0;
            y <= y + 11'd1;
        end else if (href_r) begin
            x <= x + 11'd1;
        end
    end
end

// Tọa độ trong vùng cắt
wire [10:0] xo = x - X0;
wire [10:0] yo = y - Y0;
wire in_x   = (x >= X0) && (x < X0 + 11'd448);
wire in_y   = (y >= Y0) && (y < Y0 + 11'd448);
wire row_ok = in_y && (yo[1:0] == 2'd0);         // hàng được giữ (1 trên 4)

wire [6:0] oy   = yo[8:2];                        // hàng ra 0..111
wire [4:0] band = oy[6:2];                        // band 0..27
wire [1:0] r    = oy[1:0];                        // hàng trong band 0..3
wire [6:0] ox   = xo[8:2];                        // cột ra 0..111
wire [4:0] c    = ox[6:2];                        // word trong hàng 0..27

// ---------------------------------------------------------------------------
// Điều khiển band
// ---------------------------------------------------------------------------
reg [4:0]  b_exp;       // band đang chờ ghi
reg        armed;       // MCU đã cho phép ghi
reg        cap;         // đang ghi band b_exp
reg [7:0]  p0;          // pixel cột 4k (chờ cộng với cột 4k+1)
reg [23:0] pack;        // 3 pixel đầu của word đang ghép

wire [8:0] pair = {1'b0, p0} + {1'b0, pix_r};
wire [7:0] gray = pair[8:1];                      // trung bình 2 pixel cạnh nhau

always @(posedge pclk or negedge rst_n) begin
    if (!rst_n) begin
        b_exp <= 5'd0; armed <= 1'b0; cap <= 1'b0; p0 <= 8'd0; pack <= 24'd0;
        band_we <= 1'b0; band_waddr <= 7'd0; band_wdata <= 32'd0; done_tgl <= 1'b0;
    end else begin
        band_we <= 1'b0;

        // lệnh từ MCU
        if (cmd_frame) begin
            b_exp <= 5'd0;
            armed <= 1'b1;
            cap   <= 1'b0;
        end else if (cmd_band) begin
            armed <= 1'b1;
        end

        // đầu hàng: bắt đầu band nếu đúng band chờ, hàng r = 0, đã được cho phép
        if (href_rise && !cmd_frame) begin
            if (armed && row_ok && band == b_exp && r == 2'd0)
                cap <= 1'b1;
        end

        // ghi pixel
        if (cap && href_r && row_ok && in_x) begin
            case (xo[1:0])
                2'd0: p0 <= pix_r;
                2'd1: begin
                    case (ox[1:0])
                        2'd0: pack[7:0]   <= gray;
                        2'd1: pack[15:8]  <= gray;
                        2'd2: pack[23:16] <= gray;
                        2'd3: begin
                            band_we    <= 1'b1;
                            band_waddr <= {2'd0, r} * 7'd28 + {2'd0, c};
                            band_wdata <= {gray, pack};
                            // word cuối của hàng cuối trong band -> xong band
                            if (r == 2'd3 && c == 5'd27) begin
                                cap      <= 1'b0;
                                armed    <= 1'b0;
                                done_tgl <= ~done_tgl;
                                b_exp    <= (b_exp == 5'd27) ? 5'd0 : b_exp + 5'd1;
                            end
                        end
                    endcase
                end
                default: ;
            endcase
        end

        // camera sang frame mới giữa chừng band -> bỏ band dở, chờ lần sau
        if (vs_edge)
            cap <= 1'b0;
    end
end

endmodule
