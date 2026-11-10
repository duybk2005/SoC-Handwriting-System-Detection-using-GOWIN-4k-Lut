// bias_buf.v - "16 bias INT32" (Figure 1, GD10)
//
// Nhan byte tu HyperRAM (qua mux, load_select = 0), ghep INT32 little-endian
// (manifest.json word32_byte_order). Byte thu j cua lane l nam o bit [l*32 + j*8 +: 8].
//   conv_mode = 1: chi nap 1 gia tri B[m] (4 byte); moi byte ghi dong thoi vao ca 16 lane
//                  -> 16 lane cung bias (slide 17)
//   conv_mode = 0: nap 16 gia tri B[m0..m0+15] (toi da 64 byte), byte thu b vao lane b/4 (slide 17)
module bias_buf (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         conv_mode,
    input  wire         ld_start,   // bat dau 1 lan nap moi (reset bo dem byte)
    input  wire         ld_we,
    input  wire [7:0]   ld_data,
    output wire [511:0] bias
);

    reg [5:0] bcnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n)        bcnt <= 6'd0;
        else if (ld_start) bcnt <= 6'd0;
        else if (ld_we)    bcnt <= bcnt + 6'd1;
    end

    genvar l;
    generate
        for (l = 0; l < 16; l = l + 1) begin : lane
            reg  [31:0] b;
            wire [3:0]  lane_idx = l;
            wire        sel = conv_mode | (bcnt[5:2] == lane_idx);
            always @(posedge clk or negedge rst_n) begin
                if (!rst_n) b <= 32'd0;
                else if (ld_we && sel) b[{bcnt[1:0], 3'b000} +: 8] <= ld_data;
            end
            assign bias[l*32 +: 32] = b;
        end
    endgenerate

endmodule
