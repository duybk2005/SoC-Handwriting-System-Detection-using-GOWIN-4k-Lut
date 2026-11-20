// =============================================================================
// tb_mac.v  -  Test STEP 2: module mac
//   Test 1: 784 cot cua C1, kenh o=0  (x la UINT8, K = 25)  dung du lieu that
//   Test 2: 100 cot cua C3, kenh o=0  (x la INT8,  K = 150) dung du lieu that
//   Test 3: 2000 tong ngau nhien, w va x co ca so am / so lon (bat loi dau)
// Moi lan: load bias, roi cho en=1 trong K chu ky, so acc voi tong tinh bang for.
// =============================================================================
`timescale 1ns/1ps
module tb_mac;
  // ---- Ket noi voi mac ----
  reg               clk = 0;
  reg               load = 0, en = 0, x_unsigned = 1;
  reg  signed [31:0] bias = 0;
  reg         [7:0]  w = 0, x = 0;
  wire signed [31:0] acc;

  mac dut (.clk(clk), .load(load), .en(en), .bias(bias),
           .w(w), .x(x), .x_unsigned(x_unsigned), .acc(acc));

  always #5 clk = ~clk;          // clock 100 MHz (chu ky 10 ns)

  // ---- Du lieu that ----
  reg [7:0]  w1 [0:149];   reg [31:0] b1 [0:5];   reg [7:0] p1 [0:19599];
  reg [7:0]  w2 [0:2399];  reg [31:0] b2 [0:15];  reg [7:0] p2 [0:14999];

  // ---- Bang tam cho 1 lan tinh ----
  reg [7:0]  tw [0:149];    // K trong so
  reg [7:0]  tx [0:149];    // K input
  integer n, k, t, len, err, cnt;
  reg signed [63:0] ref;

  // Chay 1 phep tinh: acc = bias + sum(tw[k]*tx[k]), k = 0..len-1
  task run_one;
    input signed [31:0] b;
    input integer       kk;
    input               xu;
    begin
      // tinh dap an bang vong for (64 bit cho chac)
      ref = b;
      for (k = 0; k < kk; k = k + 1)
        ref = ref + $signed({tw[k][7], tw[k]}) *
                    (xu ? $signed({1'b0, tx[k]}) : $signed({tx[k][7], tx[k]}));

      // dieu khien mac: doi tin hieu o canh xuong de tranh "dua" voi canh len
      @(negedge clk); load = 1; bias = b; x_unsigned = xu;
      @(negedge clk); load = 0;
      for (k = 0; k < kk; k = k + 1) begin
        en = 1; w = tw[k]; x = tx[k];
        @(negedge clk);
      end
      en = 0;

      cnt = cnt + 1;
      if (acc !== ref[31:0]) begin
        err = err + 1;
        if (err <= 10) $display("FAIL lan %0d: acc=%0d  dung phai la %0d", cnt, acc, ref);
      end
    end
  endtask

  initial begin
    $readmemh("../data/weights/c1_weight.mem", w1); $readmemh("../data/weights/c1_bias.mem", b1);
    $readmemh("../data/weights/c3_weight.mem", w2); $readmemh("../data/weights/c3_bias.mem", b2);
    $readmemh("../data/golden/block1_I.hex", p1);  $readmemh("../data/golden/block2_I.hex", p2);
    err = 0; cnt = 0;

    // ---- Test 1: C1, kenh 0, tat ca 784 cot ----
    for (n = 0; n < 784; n = n + 1) begin
      for (t = 0; t < 25; t = t + 1) begin tw[t] = w1[t]; tx[t] = p1[t*784 + n]; end
      run_one(b1[0], 25, 1'b1);
    end
    $display("Test 1 (C1, 784 cot)   xong, loi tich luy = %0d", err);

    // ---- Test 2: C3, kenh 0, tat ca 100 cot ----
    for (n = 0; n < 100; n = n + 1) begin
      for (t = 0; t < 150; t = t + 1) begin tw[t] = w2[t]; tx[t] = p2[t*100 + n]; end
      run_one(b2[0], 150, 1'b0);
    end
    $display("Test 2 (C3, 100 cot)   xong, loi tich luy = %0d", err);

    // ---- Test 3: ngau nhien, co ca x am (8'h80 = -128) va x = 255 ----
    for (n = 0; n < 2000; n = n + 1) begin
      len = 1 + ({$random} % 150);
      for (t = 0; t < len; t = t + 1) begin tw[t] = $random; tx[t] = $random; end
      run_one($random % 100000, len, n[0]);   // xen ke UINT8 / INT8
    end
    $display("Test 3 (ngau nhien)    xong, loi tich luy = %0d", err);

    if (err == 0) $display("PASS tb_mac: %0d phep tinh, 0 loi", cnt);
    else          $display("FAIL tb_mac: %0d / %0d phep tinh sai", err, cnt);
    $stop;
  end
endmodule
