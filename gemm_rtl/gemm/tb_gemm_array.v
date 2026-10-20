`timescale 1ns/1ps
module tb_gemm_array;
    reg                 clk = 0, rst_n = 0, clear = 0;
    reg  [16*32-1:0]    bias;
    reg  signed [7:0]   broadcast;
    reg  [16*8-1:0]     element;
    wire                tick;
    wire [16*32-1:0]    result;

    gemm_array dut (.clk(clk), .rst_n(rst_n), .clear(clear), .bias(bias),
                    .broadcast(broadcast), .element(element),
                    .tick(tick), .result(result));

    always #5 clk = ~clk;

    integer i, errors = 0, tick_cnt = 0;
    always @(posedge clk) if (tick) tick_cnt <= tick_cnt + 1;

    reg signed [31:0] exp_v, got_v;

    initial begin
        broadcast = 0; element = 0; bias = 0;
        for (i = 0; i < 16; i = i + 1) begin
            bias[i*32 +: 32]   = i * 100 - 500;     // co bias am/duong
            element[i*8 +: 8]  = i - 8;             // -8 .. 7
        end
        #22 rst_n = 1;

        @(negedge clk) begin clear = 1; broadcast = 3; end   // nap bias
        @(negedge clk) clear = 0;
        repeat (8) @(negedge clk);                           // 8 buoc tich luy
        broadcast = 0;                                       // dung tich luy

        for (i = 0; i < 16; i = i + 1) begin
            exp_v = (i*100 - 500) + 8 * 3 * (i - 8);
            got_v = result[i*32 +: 32];
            if (got_v !== exp_v) begin
                errors = errors + 1;
                $display("LANE %0d: got %0d expected %0d", i, got_v, exp_v);
            end
        end
        if (tick_cnt !== 2) begin
            errors = errors + 1;
            $display("tick count = %0d (expected 2)", tick_cnt);
        end
        if (errors == 0) $display("PASS");
        else             $display("FAIL: %0d errors", errors);
        $finish;
    end
endmodule
