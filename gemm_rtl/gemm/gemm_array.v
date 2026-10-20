//==============================================================================
// Module : gemm_array
// Target : Gowin GW1NSR-LV4C (Tang Nano 4K), Verilog-2001
// Desc   : 16-lane output-stationary MAC array for the LeNet-5 GEMM engine.
//          A[M x N] = W[M x K] * P[K x N] + B   (one 1x16 output block / pass)
//
//          Each lane i keeps its own INT32 accumulator ("output stationary").
//          Every clock cycle in a block:
//              acc[i] <= acc[i] + broadcast_in * element_in[i]
//          broadcast_in : w[0,k]  (one INT8 weight, shared by all lanes)
//          element_in   : p[k,0..15]  (16 INT8 activations)
//
// Protocol (matches controller block diagram):
//   1. Controller drives bias_in / k_length and pulses `clear` for 1+ cycle.
//        -> acc[i] <= bias[i], k_cnt <= 0, array armed.
//   2. In the cycle AFTER `clear` falls (first cycle with clear == 0), the
//      FIFO / ping-pong buffer must present element k = 0 together with its
//      weight on broadcast_in. One new (weight, element) pair per cycle for
//      k_length cycles in total.
//   3. The edge that accumulates the last pair (k = k_length-1) also raises
//      `tick` (registered). While tick == 1, result_out holds the final sums.
//   4. After tick the array stops accumulating and holds result_out until the
//      next `clear`.
//
// Notes:
//   * `tick` is an OUTPUT (1-cycle pulse) to the controller, per the block
//     diagram. Controller then asserts `save`/`address` to the Out_buffer.
//   * k_length is a runtime port (LeNet-5 layers need different K, e.g.
//     conv1 K=25, conv2 K=150, fc1 K=400, ...). Tie to 16'd25 for fixed use.
//   * Reset is asynchronous assert (active-low), synchronous release.
//==============================================================================
`timescale 1ns / 1ps

module gemm_array (
    input  wire         clk,
    input  wire         rst_n,

    input  wire         clear,         // reload bias, restart K counter
    input  wire [15:0]  k_length,      // number of accumulation cycles (K)

    input  wire [511:0] bias_in,       // 16 x INT32, lane i = [32*i +: 32]
    input  wire [7:0]   broadcast_in,  // INT8 weight, shared by all lanes
    input  wire [127:0] element_in,    // 16 x INT8,  lane i = [8*i  +: 8]

    output reg          tick,          // 1-cycle pulse: K cycles completed
    output wire [511:0] result_out     // 16 x INT32 accumulators
);

    //--------------------------------------------------------------------------
    // Control: K-cycle counter, run flag, tick
    //--------------------------------------------------------------------------
    reg  [15:0] k_cnt;
    reg         running;

    // Last cycle of the block. k_length == 0 is treated like 1.
    wire        last_cycle = (k_length <= 16'd1) || (k_cnt == (k_length - 16'd1));

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            k_cnt   <= 16'd0;
            running <= 1'b0;
            tick    <= 1'b0;
        end else if (clear) begin
            k_cnt   <= 16'd0;
            running <= 1'b1;
            tick    <= 1'b0;
        end else begin
            tick <= 1'b0;                       // default: single-cycle pulse
            if (running) begin
                if (last_cycle) begin
                    running <= 1'b0;            // hold results until next clear
                    tick    <= 1'b1;            // aligned with final acc value
                end else begin
                    k_cnt <= k_cnt + 16'd1;
                end
            end
        end
    end

    //--------------------------------------------------------------------------
    // 16 MAC lanes
    //--------------------------------------------------------------------------
    wire signed [7:0] w_s = broadcast_in;

    genvar i;
    generate
        for (i = 0; i < 16; i = i + 1) begin : g_lane
            wire signed [7:0]  elem_s = element_in[8*i +: 8];
            wire signed [15:0] prod   = w_s * elem_s;      // INT8 x INT8 -> INT16
            reg  signed [31:0] acc;

            always @(posedge clk or negedge rst_n) begin
                if (!rst_n)
                    acc <= 32'sd0;
                else if (clear)
                    acc <= $signed(bias_in[32*i +: 32]);
                else if (running)
                    // both operands signed -> prod is sign-extended to 32 bit
                    acc <= acc + prod;
            end

            assign result_out[32*i +: 32] = acc;
        end
    endgenerate

endmodule
