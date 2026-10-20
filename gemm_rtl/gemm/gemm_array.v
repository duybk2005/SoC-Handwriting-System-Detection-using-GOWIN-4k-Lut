//============================================================================
// GEMM Array  -  16 lane MAC, INT8 x INT8 -> INT32 accumulate
//----------------------------------------------------------------------------
// Moi nhip clock (sau clear):
//     acc[i] <= acc[i] + broadcast * element[i]      i = 0..15
// clear = 1 : acc[i] <= bias[i]  (xoa tich luy cu, nap lai bias), reset bo dem n
// tick      : xung 1 chu ky sau moi N_STEP (=4) buoc tich luy -> controller
//             dao vung Ping <-> Pong cua Element buffer
// result    : 16 x INT32 (thanh ghi tich luy), controller dung save/address
//             de ghi vao Out_buffer
//
// Cong (khop so do):
//   bias      : 16 x INT32  (tu 16 bias INT32)
//   broadcast : 1  x INT8   (tu K INT8 / Broadcast buffer)
//   element   : 16 x INT8   (tu Ping-pong buffer)
//   clear     : tu controller
//   tick      : den controller
//   result    : 16 x INT32 den Out_buffer
//============================================================================
module gemm_array #(
    parameter LANES  = 16,   // so cot song song (16)
    parameter N_STEP = 4     // n = 4 buoc tich luy moi lan tick
)(
    input  wire                      clk,
    input  wire                      rst_n,                  // reset bat dong, active low

    input  wire                      clear,                  // tu controller
    input  wire [LANES*32-1:0]       bias,                   // bias(16) INT32
    input  wire signed [7:0]         broadcast,              // broadcast INT8
    input  wire [LANES*8-1:0]        element,                // element(16) INT8

    output reg                       tick,                   // den controller
    output wire [LANES*32-1:0]       result                  // result(16) INT32
);

    // ------------------------------------------------------------------
    // Bo dem n-loop
    // ------------------------------------------------------------------
    localparam CNT_W = (N_STEP <= 2) ? 1 : $clog2(N_STEP);
    reg [CNT_W-1:0] cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            cnt  <= {CNT_W{1'b0}};
            tick <= 1'b0;
        end else if (clear) begin
            cnt  <= {CNT_W{1'b0}};
            tick <= 1'b0;
        end else begin
            if (cnt == N_STEP-1) begin
                cnt  <= {CNT_W{1'b0}};
                tick <= 1'b1;        // hoan thanh 1 nhom n buoc
            end else begin
                cnt  <= cnt + 1'b1;
                tick <= 1'b0;
            end
        end
    end

    // ------------------------------------------------------------------
    // 16 MAC lane
    // ------------------------------------------------------------------
    genvar i;
    generate
        for (i = 0; i < LANES; i = i + 1) begin : g_mac
            wire signed [7:0]  elem_i = element[i*8 +: 8];
            wire signed [31:0] bias_i = bias[i*32 +: 32];
            wire signed [15:0] prod   = broadcast * elem_i;   // INT8 x INT8 -> INT16

            reg  signed [31:0] acc;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    acc <= 32'sd0;
                else if (clear)
                    acc <= bias_i;                            // nap bias moi vong K-loop
                else
                    acc <= acc + {{16{prod[15]}}, prod};      // sign-extend + cong don
            end

            assign result[i*32 +: 32] = acc;
        end
    endgenerate

endmodule
