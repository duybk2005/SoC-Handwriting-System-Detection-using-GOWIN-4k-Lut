// digit_7seg.v — Vẽ 1 chữ số kiểu LED 7 đoạn lên HDMI
// ----------------------------------------------------------------------------
// Tái sử dụng từ svo_digit.v (nhánh Peripheral/display_digit_hdmi):
//   - đồng bộ ngõ vào 2 flip-flop
//   - decoder one-hot -> 7 đoạn {g,f,e,d,c,b,a}, giá trị không hợp lệ -> gạch ngang
//   - vẽ 7 đoạn bằng 7 hình chữ nhật, chỉ so sánh toạ độ (không cần font ROM)
// Khác bản gốc:
//   - Ngõ vào là số nhị phân 4 bit (thanh ghi Digit của MCU), đổi sang one-hot bên trong.
//     0..9 -> hiện số, 14 -> chữ 'E' (mạng không đủ tự tin),
//     giá trị khác (vd 15 khi khung hình trống) -> gạch ngang.
//   - Không tự sinh AXI-stream: chỉ trả cờ cho pixel hiện tại để svo_hdmi chồng lên
//     ảnh 28x28 và các ô debug. Bỏ chế độ AUTO_TEST.
//   - Có thêm khung nền (panel) bao quanh chữ số.
// ----------------------------------------------------------------------------
module digit_7seg #(
    parameter XB = 14,          // độ rộng toạ độ (`SVO_XYBITS)
    parameter X0 = 492,         // góc trên trái của chữ số
    parameter Y0 = 160,
    parameter W  = 96,          // rộng
    parameter H  = 160,         // cao
    parameter T  = 18,          // độ dày nét
    parameter M  = 16           // lề của khung nền quanh chữ số
)(
    input  wire          clk,       // clk_pixel
    input  wire [3:0]    digit,     // từ thanh ghi Digit (miền clk_sys)
    input  wire [XB-1:0] hcursor,
    input  wire [XB-1:0] vcursor,
    output wire          panel,     // pixel nằm trong khung nền
    output wire          on         // pixel thuộc đoạn đang sáng
);

    // ---------- 1. đồng bộ ngõ vào (digit thuộc miền clk_sys) ----------
    reg [3:0] d_s1, d_s2;
    always @(posedge clk) begin
        d_s1 <= digit;
        d_s2 <= d_s1;
    end

    // nhị phân -> one-hot, giữ đúng giao diện decoder của svo_digit
    wire [9:0] din_sel = (d_s2 <= 4'd9) ? (10'b1 << d_s2) : 10'b0;

    // ---------- 2. decoder one-hot -> 7 đoạn {g,f,e,d,c,b,a} (giữ nguyên bản gốc, thêm 'E') ----------
    reg [6:0] seg;
    always @(*) begin
        if (d_s2 == 4'd14)
            seg = 7'b1111001;                 // E: a, d, e, f, g
        else case (din_sel)
            10'b0000000001: seg = 7'b0111111; // 0
            10'b0000000010: seg = 7'b0000110; // 1
            10'b0000000100: seg = 7'b1011011; // 2
            10'b0000001000: seg = 7'b1001111; // 3
            10'b0000010000: seg = 7'b1100110; // 4
            10'b0000100000: seg = 7'b1101101; // 5
            10'b0001000000: seg = 7'b1111101; // 6
            10'b0010000000: seg = 7'b0000111; // 7
            10'b0100000000: seg = 7'b1111111; // 8
            10'b1000000000: seg = 7'b1101111; // 9
            default:        seg = 7'b1000000; // không hợp lệ -> chỉ hiện gạch ngang
        endcase
    end

    // ---------- 3. vẽ 7 hình chữ nhật (giữ nguyên bản gốc) ----------
    wire [XB-1:0] xr = hcursor - X0;
    wire [XB-1:0] yr = vcursor - Y0;

    wire inside = (hcursor >= X0) && (hcursor < X0 + W) &&
                  (vcursor >= Y0) && (vcursor < Y0 + H);

    wire sa = (yr <  T);
    wire sg = (yr >= H/2 - T/2) && (yr < H/2 + T/2);
    wire sd = (yr >= H - T);
    wire sf = (xr <  T)     && (yr <  H/2);
    wire se = (xr <  T)     && (yr >= H/2);
    wire sb = (xr >= W - T) && (yr <  H/2);
    wire sc = (xr >= W - T) && (yr >= H/2);

    assign on = inside & ((seg[0] & sa) | (seg[1] & sb) | (seg[2] & sc) |
                          (seg[3] & sd) | (seg[4] & se) | (seg[5] & sf) |
                          (seg[6] & sg));

    assign panel = (hcursor >= X0 - M) && (hcursor < X0 + W + M) &&
                   (vcursor >= Y0 - M) && (vcursor < Y0 + H + M);

endmodule
