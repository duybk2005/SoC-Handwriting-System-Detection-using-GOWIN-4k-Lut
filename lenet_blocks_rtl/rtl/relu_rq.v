// =============================================================================
// relu_rq.v  —  STEP 1: H = RQ(ReLU(Acc))   (to hop, combinational)
// -----------------------------------------------------------------------------
// Cong thuc (INTEGER_SPEC.md muc 4, shift = 30 cho C1/C3/C5/F6):
//   positive = max(acc, 0)
//   wide     = (positive * MULT + 2^29) >> 30
//   q_out    = min(wide, 127)
//
// Do rong bit:
//   - acc duong lon nhat (theo bounds.json) ~ 1.06e6  < 2^21
//   - MULT lon nhat = 3025526                         < 2^22
//   => tich < 2^43. Dung 44 bit la du, nhung de an toan dung 32+23 = 55 bit.
//   - Vi acc la INT32 nen de toan dien ta van xu ly acc den 2^31-1:
//     tich max ~ 2^31 * 2^22 = 2^53 -> 55 bit khong tran.
// =============================================================================
`timescale 1ns/1ps
module relu_rq #(
    parameter [22:0] MULT  = 23'd1669522,   // C1 mac dinh
    parameter        SHIFT = 30
)(
    input  wire signed [31:0] acc,
    output wire        [7:0]  q_out          // 0..127 (bit7 luon = 0)
);
    // 1) ReLU: am -> 0. Sau buoc nay so khong am, chi can 31 bit.
    wire [30:0] pos  = acc[31] ? 31'd0 : acc[30:0];

    // 2) Nhan voi multiplier + cong offset lam tron (nua don vi lam tron len)
    wire [54:0] prod = pos * MULT;
    wire [54:0] rnd  = prod + (55'd1 << (SHIFT - 1));

    // 3) Dich phai SHIFT bit
    wire [54:0] wide = rnd >> SHIFT;

    // 4) Bao hoa ve 127
    assign q_out = (wide > 55'd127) ? 8'd127 : {1'b0, wide[6:0]};
endmodule
