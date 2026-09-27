`timescale 1ns/1ps
// One UINT8 x INT8 lane. E0: operands, E1: DSP pipeline,
// E2: product output register, E3: accumulate. One beat per clock.
// load_bias starts a new dot product and flushes pending pipeline tokens.
module mac_lane (
    input wire clk, input wire rst,
    input wire load_bias,
    input wire signed [31:0] bias_in,
    input wire in_valid, input wire in_last,
    input wire [7:0] x_in,
    input wire signed [7:0] w_in,
    output reg signed [31:0] acc_q,
    output reg done
);
    wire signed [16:0] mul_q;
    reg [2:0] valid_q, last_q;
    wire signed [31:0] product_ext = {{15{mul_q[16]}}, mul_q};

`ifndef PORTABLE_MAC
    wire [35:0] dsp_product;
    // Extend into native DSP ports; useful product remains signed 17-bit.
    MULT18X18 #(.AREG(1'b1), .BREG(1'b1), .PIPE_REG(1'b1),
        .OUT_REG(1'b1), .ASIGN_REG(1'b0), .BSIGN_REG(1'b0),
        .SOA_REG(1'b0), .MULT_RESET_MODE("SYNC")) u_mult (
        .A({10'b0,x_in}), .B({{10{w_in[7]}},w_in}),
        .ASIGN(1'b1), .BSIGN(1'b1), .ASEL(1'b0), .BSEL(1'b0),
        .SIA(18'd0), .SIB(18'd0), .CLK(clk), .CE(1'b1), .RESET(1'b0),
        .DOUT(dsp_product), .SOA(), .SOB()
    );
    assign mul_q = dsp_product[16:0];
`else
    reg signed [8:0] x_q;
    reg signed [7:0] w_q;
    reg signed [16:0] product_pipe, product_out;
    // Portable cycle-equivalent model. Target builds use DSP by default.
    always @(posedge clk) begin
        x_q <= $signed({1'b0, x_in});
        w_q <= w_in;
        product_pipe <= x_q * w_q;
        product_out <= product_pipe;
    end
    assign mul_q = product_out;
`endif

    always @(posedge clk) begin
        if (rst) begin
            acc_q <= 32'sd0;
            valid_q <= 3'b0;
            last_q <= 3'b0;
            done <= 1'b0;
        end else if (load_bias) begin
            acc_q <= bias_in;
            valid_q <= 3'b0;
            last_q <= 3'b0;
            done <= 1'b0;
        end else begin
            valid_q <= {valid_q[1:0],in_valid};
            last_q <= {last_q[1:0],in_valid && in_last};
            done <= valid_q[2] && last_q[2];
            if (valid_q[2])
                acc_q <= acc_q + product_ext;
        end
    end
endmodule
