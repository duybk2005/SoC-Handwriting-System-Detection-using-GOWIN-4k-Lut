// =============================================================================
// syn_wrap.v  -  STEP 7: Wrapper CHI de tong hop do tai nguyen / Fmax
// -----------------------------------------------------------------------------
// Van de: gemm_engine co ~150 chan I/O, block3_top ~250 chan, nhung chip
// GW1NSR-4C (QFN48) chi co ~40 chan. Place & Route se bao loi thieu chan.
//
// Cach giai (thuong dung khi do tai nguyen 1 module):
//   - Tat ca input du lieu lay tu 1 thanh ghi dich, nap noi tiep qua 1 chan `sin`.
//   - Tat ca output dua qua thanh ghi roi XOR-gop thanh 1 chan `sout`.
//   => chi con 5 chan: clk, rst_n, start, sin, sout (+ done).
//   XOR-gop giup cong cu KHONG xoa logic (vi output nao cung anh huong `sout`).
//
// Chi phi cua wrapper (thanh ghi dich + XOR) duoc ghi rieng trong ROADMAP.
// =============================================================================
`timescale 1ns/1ps

// ---------------- Wrapper cho gemm_engine (cau hinh C1) ----------------
module syn_wrap_gemm (
    input  wire clk, rst_n, start, sin,
    output wire done,
    output reg  sout
);
    reg  [47:0] in_sr;                       // b_data(32) + w_data(8) + x_data(8)
    always @(posedge clk) in_sr <= {in_sr[46:0], sin};

    wire [6:0]  b_addr;  wire [15:0] w_addr;  wire [14:0] x_addr;
    wire        out_we, busy;  wire [12:0] out_addr;  wire [31:0] out_data;

    gemm_engine #(.M(6), .K(25), .N(784), .X_UNSIGNED(1), .DO_RQ(1),
                  .MULT(23'd1669522)) u_dut (
        .clk(clk), .rst_n(rst_n), .start(start), .busy(busy), .done(done),
        .b_addr(b_addr), .b_data(in_sr[47:16]),
        .w_addr(w_addr), .w_data(in_sr[15:8]),
        .x_addr(x_addr), .x_data(in_sr[7:0]),
        .out_we(out_we), .out_addr(out_addr), .out_data(out_data));

    reg [84:0] out_r;
    always @(posedge clk) begin
        out_r <= {b_addr, w_addr, x_addr, out_we, busy, out_addr, out_data};
        sout  <= ^out_r;
    end
endmodule

// ---------------- Wrapper cho block3_top (C5 -> F6 -> Output) ----------------
module syn_wrap_block3 (
    input  wire clk, rst_n, start, sin,
    output wire done,
    output reg  sout
);
    reg  [127:0] in_sr;   // w3,v,w4,w5 (4x8) + b3,b4,b5 (3x32)
    always @(posedge clk) in_sr <= {in_sr[126:0], sin};

    wire [15:0] w3_addr, w4_addr, w5_addr;
    wire [6:0]  b3_addr, b4_addr, b5_addr;
    wire [14:0] v_addr;
    wire        logit_we, busy;  wire [3:0] logit_addr;  wire [31:0] logit_data;

    block3_top u_dut (
        .clk(clk), .rst_n(rst_n), .start(start), .busy(busy), .done(done),
        .w3_addr(w3_addr), .w3_data(in_sr[7:0]),   .b3_addr(b3_addr), .b3_data(in_sr[63:32]),
        .v_addr(v_addr),   .v_data(in_sr[15:8]),
        .w4_addr(w4_addr), .w4_data(in_sr[23:16]), .b4_addr(b4_addr), .b4_data(in_sr[95:64]),
        .w5_addr(w5_addr), .w5_data(in_sr[31:24]), .b5_addr(b5_addr), .b5_data(in_sr[127:96]),
        .logit_we(logit_we), .logit_addr(logit_addr), .logit_data(logit_data));

    reg [123:0] out_r;
    always @(posedge clk) begin
        out_r <= {w3_addr, w4_addr, w5_addr, b3_addr, b4_addr, b5_addr, v_addr,
                  logit_we, busy, logit_addr, logit_data};
        sout  <= ^out_r;
    end
endmodule
