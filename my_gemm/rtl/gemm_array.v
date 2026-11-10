// gemm_array.v - 16-lane MAC array, Output-Stationary (slide 14, 15, 16, 17)
//
// Moi nhip (en = 1): acc[i] = acc[i] + broadcast * element[i], i = 0..15   (detail.md TF 4)
// clear = 1        : acc[i] = bias[i]  (xoa tich luy cu va nap bias)      (detail.md TF 3)
// tick  = 1        : bao het 1 bank n = 4 nhip (hoac nhip cuoi cua K)      (Figure 1, GD9)
//
// Pipeline 2 tang (de Gowin map phep nhan vao 16 khoi DSP MULT9X9):
//   tang 1 (en)    : prod_r = broadcast * element[i]   (tick phat o tang nay)
//   tang 2 (en_d)  : acc    = acc + prod_r
//   -> busy = 1 khi con tich dang cho cong; controller cho busy = 0 roi moi save.
//
// Co dau / khong dau (GD12): weight INT8 co dau, activation khong dau.
//   conv_mode = 1: broadcast = weight (co dau), element = activation (khong dau)
//   conv_mode = 0: broadcast = activation (khong dau), element = weight (co dau)
// Accumulator INT32, khong bao hoa (GD13).
module gemm_array (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         conv_mode,
    input  wire [15:0]  k_len,      // K cua phase hien tai
    input  wire         clear,
    input  wire         en,
    input  wire [7:0]   broadcast,
    input  wire [127:0] element,    // lane i = element[i*8 +: 8]
    input  wire [511:0] bias,       // lane i = bias[i*32 +: 32]
    output wire         tick,
    output wire         busy,
    output wire [511:0] result      // lane i = result[i*32 +: 32]
);

    // Dem so nhip da tich luy trong block hien tai
    reg [15:0] cnt;
    reg        en_d;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt  <= 16'd0;
            en_d <= 1'b0;
        end else begin
            en_d <= en;
            if (clear)   cnt <= 16'd0;
            else if (en) cnt <= cnt + 16'd1;
        end
    end

    assign tick = en & ((cnt[1:0] == 2'b11) | (cnt == k_len - 16'd1));
    assign busy = en_d;

    // broadcast mo rong 9 bit: co dau neu la weight
    wire signed [8:0] b_ext = conv_mode ? {broadcast[7], broadcast} : {1'b0, broadcast};

    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : lane
            wire        [7:0]  e     = element[i*8 +: 8];
            wire signed [8:0]  e_ext = conv_mode ? {1'b0, e} : {e[7], e};
            // syn_keep: giu prod_r la thanh ghi rieng -> Gowin dung MULT9X9,
            // khong gop phep cong vao khoi MULTADDALU (chi co 8 khoi)
            reg  signed [17:0] prod_r /* synthesis syn_keep=1 */;
            reg         [31:0] acc;

            always @(posedge clk) begin
                prod_r <= e_ext * b_ext;
            end

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)      acc <= 32'd0;
                else if (clear)  acc <= bias[i*32 +: 32];
                else if (en_d)   acc <= acc + {{14{prod_r[17]}}, prod_r};
            end

            assign result[i*32 +: 32] = acc;
        end
    endgenerate

endmodule
