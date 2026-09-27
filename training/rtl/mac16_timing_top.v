`timescale 1ns/1ps
// Small-pin-count timing harness, NOT the board/HyperRAM/MCU integration.
// Scan input MSB first, 648 clocks: {bias[511:0], weights[127:0], x[7:0]}.
// Capture results with capture_result, then shift 512 bits MSB first.
module mac16_timing_top (
    input wire clk, input wire rst,
    input wire scan_en, input wire scan_in,
    input wire start, input wire layer_fc2, input wire in_valid,
    input wire capture_result, input wire result_shift,
    output wire scan_out, output wire in_ready,
    output wire busy, output wire done
);
    reg [647:0] stimulus;
    reg [511:0] result_q;
    reg scan_in_q, layer_fc2_q;
    wire [511:0] result;
    // Harness input sampling: half-cycle separation prevents short external
    // input paths from violating hold at the rising-edge core registers.
    // External scan_in/layer_fc2 must meet the falling-edge input timing.
    always @(negedge clk) begin
        scan_in_q <= scan_in;
        layer_fc2_q <= layer_fc2;
    end
    always @(posedge clk) begin
        if (scan_en) stimulus <= {stimulus[646:0], scan_in_q};
        if (capture_result) result_q <= result;
        else if (result_shift) result_q <= {result_q[510:0], 1'b0};
    end
    assign scan_out = result_q[511];
    mac16_core u_core (
        .clk(clk), .rst(rst), .start(start), .layer_fc2(layer_fc2_q),
        .bias_in(stimulus[647:136]), .weight_in(stimulus[135:8]),
        .x_in(stimulus[7:0]), .in_valid(in_valid), .in_ready(in_ready),
        .busy(busy), .done(done), .acc_out(result)
    );
endmodule
