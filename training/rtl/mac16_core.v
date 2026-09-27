`timescale 1ns/1ps
// Internal streaming interface; wide buses are NOT package pins.
// start accepted only while !busy; no data accepted on the start edge.
// FC1: 784 accepted beats, 16 lanes. FC2: 16 beats, lanes 0..9.
// Lane j occupies [j*WIDTH +: WIDTH] in every packed bus.
module mac16_core (
    input wire clk, input wire rst,
    input wire start, input wire layer_fc2,
    input wire [511:0] bias_in,
    input wire in_valid,
    output wire in_ready,
    input wire [7:0] x_in,
    input wire [127:0] weight_in,
    output reg busy,
    output wire done,
    output wire [511:0] acc_out
);
    reg receiving, fc2_q;
    reg [9:0] index_q;
    wire launch = start && !busy && !rst;
    wire accept = in_valid && in_ready;
    wire last = fc2_q ? (index_q == 10'd15) : (index_q == 10'd783);
    wire [15:0] lane_done;
    assign in_ready = receiving && !rst;
    assign done = lane_done[0];

    always @(posedge clk) begin
        if (rst) begin
            busy <= 1'b0;
            receiving <= 1'b0;
            fc2_q <= 1'b0;
            index_q <= 10'd0;
        end else if (launch) begin
            busy <= 1'b1;
            receiving <= 1'b1;
            fc2_q <= layer_fc2;
            index_q <= 10'd0;
        end else begin
            if (accept) begin
                if (last) receiving <= 1'b0;
                else index_q <= index_q + 10'd1;
            end
            if (done) busy <= 1'b0;
        end
    end

    genvar j;
    generate for (j = 0; j < 16; j = j + 1) begin: lanes
        wire active = !fc2_q || (j < 10);
        // Inactive FC2 lanes are explicitly cleared and receive no products.
        wire signed [31:0] lane_bias = (layer_fc2 && (j >= 10))
            ? 32'sd0 : $signed(bias_in[j*32 +: 32]);
        mac_lane u_mac (
            .clk(clk), .rst(rst), .load_bias(launch), .bias_in(lane_bias),
            .in_valid(accept && active), .in_last(last),
            .x_in(x_in), .w_in(weight_in[j*8 +: 8]),
            .acc_q(acc_out[j*32 +: 32]), .done(lane_done[j])
        );
    end endgenerate
endmodule
