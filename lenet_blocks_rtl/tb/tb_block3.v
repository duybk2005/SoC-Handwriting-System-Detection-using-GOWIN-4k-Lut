// =============================================================================
// tb_block3.v  -  Test STEP 5: Khoi 3 (C5 -> F6 -> Output)
//   Input : ../data/golden/block3_I.hex  (INT8  [400,1])
//   Dap an: ../data/golden/block3_O.hex  (INT32 [10,1])  = logits
//
// Ngoai logits, tb con tu tinh H3, H4 bang vong for (nhu tb_ref_model.v) va so
// voi RAM ben trong DUT (dut.h3_ram, dut.h4_ram). Neu logits sai, nhin dong
// "H3 sai" / "H4 sai" la biet lop nao hong.
// =============================================================================
`timescale 1ns/1ps
module tb_block3;
  reg clk = 0, rst_n = 0, start = 0;
  always #5 clk = ~clk;

  // ---- Bo nho ngoai (doc dong bo, tre 1 clock) ----
  reg [7:0]  w3_rom [0:47999];  reg [31:0] b3_rom [0:119];
  reg [7:0]  w4_rom [0:10079];  reg [31:0] b4_rom [0:83];
  reg [7:0]  w5_rom [0:839];    reg [31:0] b5_rom [0:9];
  reg [7:0]  v_ram  [0:399];
  reg [31:0] exp_logit [0:9];
  reg [31:0] logit_ram [0:9];

  wire [15:0] w3_addr, w4_addr, w5_addr;
  wire [6:0]  b3_addr, b4_addr, b5_addr;
  wire [14:0] v_addr;
  reg  [7:0]  w3_data, w4_data, w5_data, v_data;
  reg  [31:0] b3_data, b4_data, b5_data;
  wire        logit_we;  wire [3:0] logit_addr;  wire [31:0] logit_data;
  wire        busy, done;

  always @(posedge clk) begin
    w3_data <= w3_rom[w3_addr];  b3_data <= b3_rom[b3_addr];  v_data <= v_ram[v_addr];
    w4_data <= w4_rom[w4_addr];  b4_data <= b4_rom[b4_addr];
    w5_data <= w5_rom[w5_addr];  b5_data <= b5_rom[b5_addr];
    if (logit_we) logit_ram[logit_addr] <= logit_data;
  end

  block3_top dut (
    .clk(clk), .rst_n(rst_n), .start(start), .busy(busy), .done(done),
    .w3_addr(w3_addr), .w3_data(w3_data), .b3_addr(b3_addr), .b3_data(b3_data),
    .v_addr(v_addr),   .v_data(v_data),
    .w4_addr(w4_addr), .w4_data(w4_data), .b4_addr(b4_addr), .b4_data(b4_data),
    .w5_addr(w5_addr), .w5_data(w5_data), .b5_addr(b5_addr), .b5_data(b5_data),
    .logit_we(logit_we), .logit_addr(logit_addr), .logit_data(logit_data));

  integer cycles = 0;
  always @(posedge clk) if (busy) cycles = cycles + 1;

  // ---- Tham chieu H3, H4 (de debug) ----
  reg [7:0] ref_h3 [0:119];
  reg [7:0] ref_h4 [0:83];
  reg signed [63:0] acc;
  integer o, k, i, err, err_h3, err_h4, best;

  function [7:0] rq;
    input signed [63:0] a; input [63:0] m; reg [63:0] t;
    begin
      if (a <= 0) rq = 0;
      else begin t = (a * m + 64'd536870912) >> 30; rq = (t > 127) ? 8'd127 : t[7:0]; end
    end
  endfunction

  initial begin
    $readmemh("../data/weights/c5_weight.mem",     w3_rom); $readmemh("../data/weights/c5_bias.mem",     b3_rom);
    $readmemh("../data/weights/f6_weight.mem",     w4_rom); $readmemh("../data/weights/f6_bias.mem",     b4_rom);
    $readmemh("../data/weights/output_weight.mem", w5_rom); $readmemh("../data/weights/output_bias.mem", b5_rom);
    $readmemh("../data/golden/block3_I.hex", v_ram);
    $readmemh("../data/golden/block3_O.hex", exp_logit);

    for (o = 0; o < 120; o = o + 1) begin
      acc = $signed(b3_rom[o]);
      for (k = 0; k < 400; k = k + 1) acc = acc + $signed(w3_rom[o*400+k]) * $signed(v_ram[k]);
      ref_h3[o] = rq(acc, 1981865);
    end
    for (o = 0; o < 84; o = o + 1) begin
      acc = $signed(b4_rom[o]);
      for (k = 0; k < 120; k = k + 1) acc = acc + $signed(w4_rom[o*120+k]) * $signed(ref_h3[k]);
      ref_h4[o] = rq(acc, 3025526);
    end

    // ---- Chay DUT ----
    repeat (3) @(negedge clk);  rst_n = 1;
    @(negedge clk); start = 1;
    @(negedge clk); start = 0;
    @(posedge done);
    @(negedge clk);

    // ---- So H3, H4 (ben trong DUT) ----
    err_h3 = 0; err_h4 = 0;
    for (i = 0; i < 120; i = i + 1) if (dut.h3_ram[i] !== ref_h3[i]) err_h3 = err_h3 + 1;
    for (i = 0; i < 84;  i = i + 1) if (dut.h4_ram[i] !== ref_h4[i]) err_h4 = err_h4 + 1;
    $display("H3 (C5) sai %0d / 120,  H4 (F6) sai %0d / 84", err_h3, err_h4);

    // ---- So 10 logits voi golden ----
    err = 0; best = 0;
    for (i = 0; i < 10; i = i + 1) begin
      $display("  logit[%0d] RTL=%0d  golden=%0d  %s", i, $signed(logit_ram[i]),
               $signed(exp_logit[i]), (logit_ram[i] === exp_logit[i]) ? "OK" : "<-- SAI");
      if (logit_ram[i] !== exp_logit[i]) err = err + 1;
      if ($signed(logit_ram[i]) > $signed(logit_ram[best])) best = i;
    end
    $display("So clock = %0d,  Argmax (chu so du doan) = %0d", cycles, best);
    if (err == 0) $display("PASS Block3: 10 / 10 logits dung");
    else          $display("FAIL Block3: %0d / 10 logits sai", err);
    $stop;
  end
endmodule
