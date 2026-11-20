// =============================================================================
// tb_block2.v  -  Test STEP 4: Khoi 2 (dung lai NGUYEN gemm_engine, chi doi tham so)
//   Acc2[16x100] = W2[16x150] P2[150x100] + B2 ;  H2 = RQ2(ReLU(Acc2))
//   Input : ../data/golden/block2_I.hex  (INT8 [150,100])
//   Dap an: ../data/golden/block2_O.hex  (INT8 [16,10,10])
//
// So voi tb_block1.v chi khac 4 cho (danh dau <<<):
//   M, K, N  |  X_UNSIGNED = 0  |  MULT cua C3  |  ten file c3_* / block2_*
// =============================================================================
`timescale 1ns/1ps
module tb_block2;
  localparam M = 16, K = 150, N = 100;                     // <<<

  reg clk = 0, rst_n = 0, start = 0;
  always #5 clk = ~clk;

  // ---- Bo nho (mo hinh BSRAM: doc dong bo, tre 1 clock) ----
  reg  [7:0]  w_rom [0:M*K-1];
  reg  [31:0] b_rom [0:M-1];
  reg  [7:0]  x_ram [0:K*N-1];
  reg  [7:0]  exp_o [0:M*N-1];
  reg  [7:0]  out_ram [0:M*N-1];

  wire [6:0]  b_addr;  reg [31:0] b_data;
  wire [15:0] w_addr;  reg [7:0]  w_data;
  wire [14:0] x_addr;  reg [7:0]  x_data;
  wire        out_we;  wire [12:0] out_addr;  wire [31:0] out_data;
  wire        busy, done;

  always @(posedge clk) begin
    b_data <= b_rom[b_addr];
    w_data <= w_rom[w_addr];
    x_data <= x_ram[x_addr];
    if (out_we) out_ram[out_addr] <= out_data[7:0];
  end

  // ---- Mach can test: CUNG module gemm_engine, khac tham so ----
  gemm_engine #(.M(M), .K(K), .N(N), .X_UNSIGNED(0), .DO_RQ(1),   // <<< X_UNSIGNED = 0
                .MULT(23'd2616330)) dut (                          // <<< MULT cua C3
    .clk(clk), .rst_n(rst_n), .start(start), .busy(busy), .done(done),
    .b_addr(b_addr), .b_data(b_data), .w_addr(w_addr), .w_data(w_data),
    .x_addr(x_addr), .x_data(x_data),
    .out_we(out_we), .out_addr(out_addr), .out_data(out_data));

  integer cycles = 0;
  always @(posedge clk) if (busy) cycles = cycles + 1;

  integer i, err, nwrite = 0;
  always @(posedge clk) if (out_we) nwrite = nwrite + 1;

  initial begin
    $readmemh("../data/weights/c3_weight.mem", w_rom);       // <<<
    $readmemh("../data/weights/c3_bias.mem",   b_rom);       // <<<
    $readmemh("../data/golden/block2_I.hex",   x_ram);       // <<<
    $readmemh("../data/golden/block2_O.hex",   exp_o);       // <<<
    for (i = 0; i < M*N; i = i + 1) out_ram[i] = 8'hxx;

    repeat (3) @(negedge clk);  rst_n = 1;
    @(negedge clk); start = 1;
    @(negedge clk); start = 0;

    @(posedge done);
    @(negedge clk);

    err = 0;
    for (i = 0; i < M*N; i = i + 1)
      if (out_ram[i] !== exp_o[i]) begin
        err = err + 1;
        if (err <= 10)
          $display("FAIL kenh=%0d y=%0d x=%0d : RTL=%0d  golden=%0d",
                   i / N, (i % N) / 10, i % 10, out_ram[i], exp_o[i]);  // <<< anh 10x10
      end

    $display("So lan ghi = %0d, so clock = %0d", nwrite, cycles);
    if (err == 0) $display("PASS Block2: %0d / %0d phan tu dung", M*N, M*N);
    else          $display("FAIL Block2: %0d / %0d phan tu sai", err, M*N);
    $stop;
  end
endmodule
