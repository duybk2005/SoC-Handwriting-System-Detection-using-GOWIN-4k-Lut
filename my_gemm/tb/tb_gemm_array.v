// tb_gemm_array.v - T0: unit test rieng GEMM array
//
// Kiem tra:
//  - clear nap bias vao 16 accumulator
//  - Conv mode: broadcast co dau x element khong dau (goc -128 x 255, 127 x 255)
//  - FC mode  : broadcast khong dau x element co dau (goc 255 x -128)
//  - tick o nhip thu 4, 8, ... va o nhip cuoi khi K khong chia het 4
//  - pipeline 2 tang: ket qua dung sau khi busy = 0
`timescale 1ns/1ps
module tb_gemm_array;

    reg          clk = 1'b0;
    reg          rst_n = 1'b0;
    reg          conv_mode = 1'b1;
    reg  [15:0]  k_len = 16'd0;
    reg          clear = 1'b0;
    reg          en = 1'b0;
    reg  [7:0]   broadcast = 8'd0;
    reg  [127:0] element = 128'd0;
    reg  [511:0] bias = 512'd0;
    wire         tick, busy;
    wire [511:0] result;

    always #10 clk = ~clk;

    gemm_array u_arr (
        .clk(clk), .rst_n(rst_n), .conv_mode(conv_mode), .k_len(k_len),
        .clear(clear), .en(en), .broadcast(broadcast), .element(element),
        .bias(bias), .tick(tick), .busy(busy), .result(result)
    );

    integer errors = 0;
    integer exp_acc [0:15];
    integer tick_seen [0:15];
    integer step;

    // dem tick theo so thu tu nhip
    always @(posedge clk) begin
        if (tick) tick_seen[u_arr.cnt] = 1;
    end

    task check_result(input [8*16-1:0] name);
        integer l;
        reg [31:0] got;
        begin
            for (l = 0; l < 16; l = l + 1) begin
                got = result[l*32 +: 32];
                if (got !== exp_acc[l]) begin
                    $display("[T0][FAIL] %0s lane %0d: got %0d, exp %0d", name, l, $signed(got), exp_acc[l]);
                    errors = errors + 1;
                end
            end
        end
    endtask

    // chay 1 block: K nhip, gia tri do ham tao
    task run_block(input mode, input integer K);
        integer l, k, bval, eval_;
        begin
            conv_mode = mode;
            k_len     = K;
            for (l = 0; l < 16; l = l + 1) begin
                bias[l*32 +: 32] = 1000 * (l + 1) - 7000;   // co ca bias am
                exp_acc[l]       = 1000 * (l + 1) - 7000;
            end
            for (k = 0; k < 16; k = k + 1) tick_seen[k] = 0;
            @(negedge clk) clear = 1'b1;
            @(negedge clk) clear = 1'b0;
            for (k = 0; k < K; k = k + 1) begin
                // broadcast: xen ke cac gia tri goc
                case (k % 6)
                    0: broadcast = 8'h80;   // -128 (Conv) / 128 (FC)
                    1: broadcast = 8'h7F;   //  127
                    2: broadcast = 8'hFF;   //   -1 (Conv) / 255 (FC)
                    3: broadcast = 8'h05;
                    4: broadcast = 8'h00;
                    default: broadcast = 8'hC3;
                endcase
                for (l = 0; l < 16; l = l + 1) begin
                    element[l*8 +: 8] = (l == 0) ? 8'hFF : (l == 1) ? 8'h80 : (l * 37 + k * 11);
                end
                // gia tri ky vong
                // (khong dung "? :" vi tron signed/unsigned se mat dau)
                if (mode) bval = $signed(broadcast);
                else      bval = broadcast;
                for (l = 0; l < 16; l = l + 1) begin
                    if (mode) eval_ = element[l*8 +: 8];
                    else      eval_ = $signed(element[l*8 +: 8]);
                    exp_acc[l] = exp_acc[l] + bval * eval_;
                end
                en = 1'b1;
                @(negedge clk);
                en = 1'b0;
                // chen 1 nhip nghi giua cac nhip (mo phong stall cho DMA)
                if (k % 3 == 1) @(negedge clk);
            end
            en = 1'b0;
            @(negedge clk);
            while (busy) @(negedge clk);
            // tick: nhip 3, 7, 11, ... va nhip cuoi
            for (k = 0; k < K; k = k + 1) begin
                if (((k % 4 == 3) || (k == K - 1)) != (tick_seen[k] == 1)) begin
                    $display("[T0][FAIL] tick sai o nhip %0d (K=%0d)", k, K);
                    errors = errors + 1;
                end
            end
        end
    endtask

    initial begin
        #55 rst_n = 1'b1;

        run_block(1'b1, 6);   check_result("conv K=6");
        run_block(1'b0, 6);   check_result("fc   K=6");
        run_block(1'b1, 9);   check_result("conv K=9");
        run_block(1'b0, 16);  check_result("fc   K=16");
        run_block(1'b1, 1);   check_result("conv K=1");

        if (errors == 0) $display("[T0][PASS] gemm_array: tat ca 5 block dung");
        else             $display("[T0][FAIL] gemm_array: %0d loi", errors);
        $finish;
    end

endmodule
