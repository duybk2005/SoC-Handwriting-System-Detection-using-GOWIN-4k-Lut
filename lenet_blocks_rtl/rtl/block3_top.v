// =============================================================================
// block3_top.v  -  STEP 5: Khoi 3 = C5 -> F6 -> Output   (N = 1)
// -----------------------------------------------------------------------------
//   Acc3[120] = W3[120x400] V[400]  + B3 ;  H3 = RQ3(ReLU(Acc3))
//   Acc4[84]  = W4[84x120]  H3[120] + B4 ;  H4 = RQ4(ReLU(Acc4))
//   Logits[10]= W5[10x84]   H4[84]  + B5                 (KHONG ReLU/RQ, INT32)
//
// Cau truc:
//
//   V (ngoai) --> [ gemm C5 ] --ghi--> h3_ram[120] --doc--> [ gemm F6 ] --ghi--> h4_ram[84]
//                                                                                  |
//   logits (ngoai) <------------------------------------ [ gemm Out ] <---doc------+
//
//   - 3 instance gemm_engine (Step 3), chi khac tham so.
//   - Trong so / bias de NGOAI module (C5 co 48 000 byte, lon hon BSRAM cua
//     chip, that te se nap tu HyperRAM) -> moi lop co 1 cong doc rieng.
//   - h3_ram, h4_ram la RAM nho ben trong (doc dong bo tre 1 clock, giong tb).
//   - FSM chay lan luot: C5 xong -> F6 -> Output -> done.
// =============================================================================
`timescale 1ns/1ps
module block3_top (
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,
    output wire        busy,
    output reg         done,
    // ---- C5: trong so, bias, input V ----
    output wire [15:0] w3_addr,  input wire [7:0]  w3_data,
    output wire [6:0]  b3_addr,  input wire [31:0] b3_data,
    output wire [14:0] v_addr,   input wire [7:0]  v_data,
    // ---- F6 ----
    output wire [15:0] w4_addr,  input wire [7:0]  w4_data,
    output wire [6:0]  b4_addr,  input wire [31:0] b4_data,
    // ---- Output ----
    output wire [15:0] w5_addr,  input wire [7:0]  w5_data,
    output wire [6:0]  b5_addr,  input wire [31:0] b5_data,
    // ---- Ket qua: 10 logits INT32 ----
    output wire        logit_we,
    output wire [3:0]  logit_addr,
    output wire [31:0] logit_data
);
    // ---------------------------------------------------------------------
    // 1. FSM: chay lan luot 3 lop
    // ---------------------------------------------------------------------
    localparam [2:0] T_IDLE = 3'd0, T_C5 = 3'd1, T_F6 = 3'd2, T_OUT = 3'd3, T_DONE = 3'd4;
    reg [2:0] tstate;
    reg       go_c5, go_f6, go_out;          // xung start cho tung engine
    wire      done_c5, done_f6, done_out;

    assign busy = (tstate != T_IDLE);

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            tstate <= T_IDLE; done <= 1'b0;
            go_c5 <= 1'b0; go_f6 <= 1'b0; go_out <= 1'b0;
        end else begin
            done <= 1'b0; go_c5 <= 1'b0; go_f6 <= 1'b0; go_out <= 1'b0;
            case (tstate)
            T_IDLE: if (start)    begin go_c5  <= 1'b1; tstate <= T_C5;  end
            T_C5:   if (done_c5)  begin go_f6  <= 1'b1; tstate <= T_F6;  end
            T_F6:   if (done_f6)  begin go_out <= 1'b1; tstate <= T_OUT; end
            T_OUT:  if (done_out) tstate <= T_DONE;
            T_DONE: begin done <= 1'b1; tstate <= T_IDLE; end
            default: tstate <= T_IDLE;
            endcase
        end
    end

    // ---------------------------------------------------------------------
    // 2. RAM trung gian H3[120], H4[84]  (INT8 0..127)
    // ---------------------------------------------------------------------
    reg [7:0] h3_ram [0:119];
    reg [7:0] h4_ram [0:83];
    reg [7:0] h3_q, h4_q;                    // du lieu doc ra (tre 1 clock)

    wire        c5_we,  f6_we;
    wire [12:0] c5_waddr, f6_waddr;
    wire [31:0] c5_wdata, f6_wdata;
    wire [14:0] f6_xaddr, out_xaddr;

    always @(posedge clk) begin
        if (c5_we) h3_ram[c5_waddr[6:0]] <= c5_wdata[7:0];   // C5 ghi H3
        if (f6_we) h4_ram[f6_waddr[6:0]] <= f6_wdata[7:0];   // F6 ghi H4
        h3_q <= h3_ram[f6_xaddr[6:0]];                       // F6 doc H3
        h4_q <= h4_ram[out_xaddr[6:0]];                      // Output doc H4
    end

    // ---------------------------------------------------------------------
    // 3. Ba engine GEMM (cung module, khac tham so)
    // ---------------------------------------------------------------------
    wire        busy_c5, busy_f6, busy_out;
    wire [12:0] out_waddr;

    // C5: M=120, K=400, N=1, input INT8, co RQ
    gemm_engine #(.M(120), .K(400), .N(1), .X_UNSIGNED(0), .DO_RQ(1),
                  .MULT(23'd1981865)) u_c5 (
        .clk(clk), .rst_n(rst_n), .start(go_c5), .busy(busy_c5), .done(done_c5),
        .b_addr(b3_addr), .b_data(b3_data), .w_addr(w3_addr), .w_data(w3_data),
        .x_addr(v_addr),  .x_data(v_data),
        .out_we(c5_we), .out_addr(c5_waddr), .out_data(c5_wdata));

    // F6: M=84, K=120, N=1, input = H3, co RQ
    gemm_engine #(.M(84), .K(120), .N(1), .X_UNSIGNED(0), .DO_RQ(1),
                  .MULT(23'd3025526)) u_f6 (
        .clk(clk), .rst_n(rst_n), .start(go_f6), .busy(busy_f6), .done(done_f6),
        .b_addr(b4_addr), .b_data(b4_data), .w_addr(w4_addr), .w_data(w4_data),
        .x_addr(f6_xaddr), .x_data(h3_q),
        .out_we(f6_we), .out_addr(f6_waddr), .out_data(f6_wdata));

    // Output: M=10, K=84, N=1, input = H4, KHONG RQ -> logits INT32
    gemm_engine #(.M(10), .K(84), .N(1), .X_UNSIGNED(0), .DO_RQ(0),
                  .MULT(23'd0)) u_out (
        .clk(clk), .rst_n(rst_n), .start(go_out), .busy(busy_out), .done(done_out),
        .b_addr(b5_addr), .b_data(b5_data), .w_addr(w5_addr), .w_data(w5_data),
        .x_addr(out_xaddr), .x_data(h4_q),
        .out_we(logit_we), .out_addr(out_waddr), .out_data(logit_data));

    assign logit_addr = out_waddr[3:0];
endmodule
