// =============================================================================
// tb_relu_rq.v  -  Test STEP 1: so sanh relu_rq voi ham tham chieu 64-bit
//   (1) test bien: am, 0, 1, nguong lam tron, nguong bao hoa, INT32 max
//   (2) 100000 gia tri ngau nhien cho ca 4 multiplier (C1, C3, C5, F6)
// =============================================================================
`timescale 1ns/1ps
module tb_relu_rq;
  reg  signed [31:0] acc;
  wire [7:0] q1, q3, q5, q6;

  relu_rq #(.MULT(23'd1669522)) u_c1 (.acc(acc), .q_out(q1));
  relu_rq #(.MULT(23'd2616330)) u_c3 (.acc(acc), .q_out(q3));
  relu_rq #(.MULT(23'd1981865)) u_c5 (.acc(acc), .q_out(q5));
  relu_rq #(.MULT(23'd3025526)) u_f6 (.acc(acc), .q_out(q6));

  integer err, cnt, i;

  function [7:0] ref_rq;
    input signed [31:0] a;
    input        [63:0] m;
    reg          [63:0] t;
    begin
      if (a <= 0) ref_rq = 0;
      else begin
        t = ({32'd0, a} * m + 64'd536870912) >> 30;
        ref_rq = (t > 127) ? 8'd127 : t[7:0];
      end
    end
  endfunction

  task check;
    input signed [31:0] a;
    begin
      acc = a; #1;
      cnt = cnt + 1;
      if (q1 !== ref_rq(a,1669522) || q3 !== ref_rq(a,2616330) ||
          q5 !== ref_rq(a,1981865) || q6 !== ref_rq(a,3025526)) begin
        err = err + 1;
        if (err <= 10)
          $display("FAIL acc=%0d : got %0d %0d %0d %0d  exp %0d %0d %0d %0d", a,
                   q1, q3, q5, q6, ref_rq(a,1669522), ref_rq(a,2616330),
                   ref_rq(a,1981865), ref_rq(a,3025526));
      end
    end
  endtask

  initial begin
    err = 0; cnt = 0;
    // --- (1) Directed / corner cases ---
    check(-32'sd2147483648); check(-1); check(0); check(1);
    check(321); check(322); check(643);             // quanh nguong lam tron C1
    check(81000); check(81356); check(82000);       // quanh nguong bao hoa
    check(1000000); check(32'sd2147483647);
    // --- (2) Random ---
    for (i = 0; i < 50000; i = i + 1) check($random % 200000);   // vung hay gap
    for (i = 0; i < 50000; i = i + 1) check($random);            // toan dai INT32
    if (err == 0) $display("PASS tb_relu_rq: %0d cases, 0 mismatches", cnt);
    else          $display("FAIL tb_relu_rq: %0d / %0d mismatches", err, cnt);
    $stop;
  end
endmodule
