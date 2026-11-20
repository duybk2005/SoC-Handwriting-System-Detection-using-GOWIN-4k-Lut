// =============================================================================
// mac.v  -  STEP 2: 1 bo nhan-cong don (Multiply-ACcumulate)
// -----------------------------------------------------------------------------
// Moi canh len clk:
//   load = 1           -> acc <= bias              (bat dau 1 phan tu moi)
//   load = 0, en = 1   -> acc <= acc + w * x       (cong don 1 buoc k)
//   load = 0, en = 0   -> acc giu nguyen
//
// Kieu so:
//   w : INT8 co dau (-127..127)
//   x : C1 la UINT8 (0..255)  -> x_unsigned = 1
//       C3/C5/F6/Out la INT8  -> x_unsigned = 0
// Ca hai deu mo rong thanh 9 bit CO DAU de dung chung 1 bo nhan co dau.
// =============================================================================
`timescale 1ns/1ps
module mac (
    input  wire               clk,
    input  wire               load,
    input  wire               en,
    input  wire signed [31:0] bias,
    input  wire        [7:0]  w,
    input  wire        [7:0]  x,
    input  wire               x_unsigned,
    output reg  signed [31:0] acc
);
    // 1) Mo rong 8 -> 9 bit co dau
    //    w luon co dau: chep bit dau w[7] len.
    //    x: neu UINT8 thi them 0 o dau (200 van la +200);
    //       neu INT8 thi chep bit dau (8'hC8 = -56).
    wire signed [8:0]  w9 = {w[7], w};
    wire signed [8:0]  x9 = x_unsigned ? {1'b0, x} : {x[7], x};

    // 2) Nhan co dau 9x9 -> 18 bit (vua 1 DSP tren Gowin)
    wire signed [17:0] prod = w9 * x9;

    // 3) Cong don. Ca acc va prod deu signed nen Verilog tu mo rong dau.
    always @(posedge clk) begin
        if (load)
            acc <= bias;
        else if (en)
            acc <= acc + prod;
    end
endmodule
