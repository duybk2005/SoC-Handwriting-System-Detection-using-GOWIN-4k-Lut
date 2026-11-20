// =============================================================================
// tb_ref_model.v  -  STEP 0: Verilog "golden model" (behavioral, KHONG tong hop)
// -----------------------------------------------------------------------------
// Muc dich: chung minh du lieu (golden hex + weight .mem) khop nhau va hieu
// chinh xac cong thuc truoc khi viet RTL. Day la ban "Python golden_reference.py"
// viet lai bang Verilog. Ket qua mong doi: 3 dong "mismatches=0".
//
// Layout bo nho (row-major, giong file hex):
//   W[o][k]  -> w[o*K + k]
//   P[k][n]  -> p[k*N + n]
//   Out[o][n]-> out[o*N + n]      (block1: n = y*28 + x  => [6,28,28])
// =============================================================================
`timescale 1ns/1ps
module tb_ref_model;
  reg [7:0]  p1 [0:19599]; reg [7:0]  exp1 [0:4703];
  reg [7:0]  p2 [0:14999]; reg [7:0]  exp2 [0:1599];
  reg [7:0]  v  [0:399];   reg [31:0] exp3 [0:9];
  reg [7:0]  w1 [0:149];   reg [31:0] b1 [0:5];
  reg [7:0]  w2 [0:2399];  reg [31:0] b2 [0:15];
  reg [7:0]  w3 [0:47999]; reg [31:0] b3 [0:119];
  reg [7:0]  w4 [0:10079]; reg [31:0] b4 [0:83];
  reg [7:0]  w5 [0:839];   reg [31:0] b5 [0:9];
  reg [7:0]  h3 [0:119];   reg [7:0]  h4 [0:83];

  integer o, k, n, err;
  reg signed [63:0] acc;

  // RQ(ReLU(acc)) theo INTEGER_SPEC.md muc 4 (shift = 30 cho ca 4 lop)
  function [7:0] rq;
    input signed [63:0] a;
    input        [63:0] m;
    reg          [63:0] t;
    begin
      if (a <= 0) rq = 8'd0;
      else begin
        t  = (a * m + 64'd536870912) >> 30;    // offset = 2^29
        rq = (t > 127) ? 8'd127 : t[7:0];
      end
    end
  endfunction

  initial begin
    $readmemh("../data/golden/block1_I.hex", p1); $readmemh("../data/golden/block1_O.hex", exp1);
    $readmemh("../data/golden/block2_I.hex", p2); $readmemh("../data/golden/block2_O.hex", exp2);
    $readmemh("../data/golden/block3_I.hex", v ); $readmemh("../data/golden/block3_O.hex", exp3);
    $readmemh("../data/weights/c1_weight.mem", w1);     $readmemh("../data/weights/c1_bias.mem", b1);
    $readmemh("../data/weights/c3_weight.mem", w2);     $readmemh("../data/weights/c3_bias.mem", b2);
    $readmemh("../data/weights/c5_weight.mem", w3);     $readmemh("../data/weights/c5_bias.mem", b3);
    $readmemh("../data/weights/f6_weight.mem", w4);     $readmemh("../data/weights/f6_bias.mem", b4);
    $readmemh("../data/weights/output_weight.mem", w5); $readmemh("../data/weights/output_bias.mem", b5);

    // ---- Block 1: Acc1[6x784] = W1[6x25] P1[25x784] + B1 ; H1 = RQ1(ReLU) ----
    err = 0;
    for (o = 0; o < 6; o = o + 1)
      for (n = 0; n < 784; n = n + 1) begin
        acc = $signed(b1[o]);
        for (k = 0; k < 25; k = k + 1)                       // P1 la UINT8 -> them bit 0
          acc = acc + $signed(w1[o*25+k]) * $signed({1'b0, p1[k*784+n]});
        if (rq(acc, 1669522) !== exp1[o*784+n]) err = err + 1;
      end
    $display("Block1 mismatches=%0d / 4704", err);

    // ---- Block 2: Acc2[16x100] = W2[16x150] P2[150x100] + B2 ----
    err = 0;
    for (o = 0; o < 16; o = o + 1)
      for (n = 0; n < 100; n = n + 1) begin
        acc = $signed(b2[o]);
        for (k = 0; k < 150; k = k + 1)                      // P2 la INT8 (0..127)
          acc = acc + $signed(w2[o*150+k]) * $signed(p2[k*100+n]);
        if (rq(acc, 2616330) !== exp2[o*100+n]) err = err + 1;
      end
    $display("Block2 mismatches=%0d / 1600", err);

    // ---- Block 3: C5 -> F6 -> Output (N = 1) ----
    err = 0;
    for (o = 0; o < 120; o = o + 1) begin
      acc = $signed(b3[o]);
      for (k = 0; k < 400; k = k + 1) acc = acc + $signed(w3[o*400+k]) * $signed(v[k]);
      h3[o] = rq(acc, 1981865);
    end
    for (o = 0; o < 84; o = o + 1) begin
      acc = $signed(b4[o]);
      for (k = 0; k < 120; k = k + 1) acc = acc + $signed(w4[o*120+k]) * $signed(h3[k]);
      h4[o] = rq(acc, 3025526);
    end
    for (o = 0; o < 10; o = o + 1) begin
      acc = $signed(b5[o]);
      for (k = 0; k < 84; k = k + 1) acc = acc + $signed(w5[o*84+k]) * $signed(h4[k]);
      if (acc[31:0] !== exp3[o]) err = err + 1;              // logits: KHONG ReLU/RQ
    end
    $display("Block3 mismatches=%0d / 10", err);
    $stop;
  end
endmodule
