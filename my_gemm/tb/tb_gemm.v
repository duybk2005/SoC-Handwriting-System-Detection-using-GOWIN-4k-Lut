// tb_gemm.v - Testbench khoi GEMM (gemm_core) voi mo hinh HyperRAM
//
// Moi test:
//   1. Tao activation (P1 / P2 / V / H3 / H4), ghi vao HyperRAM model tai ACT_BASE.
//   2. Tinh ket qua chuan exp = W*P + B bang vong lap. W, B lay tu cac file .mem RIENG
//      (c1_weight.mem, ...), KHONG lay tu model_image.mem ma DUT doc -> bat duoc loi dia chi.
//   3. Xung start, cho done (co timeout).
//   4. Doc Out_buffer qua cong ob_raddr/ob_rdata:
//        Phase 1, 2: doc tung phan vung 1/4 ngay khi co ob_part_full (on-the-fly)
//        Phase 3-5 : doc M word sau khi done
//   5. So tung phan tu, in loi dau tien, kiem them so lan clear / tick / save / part_full / done.
//
// Thu tu test: T1 Phase 5 (trong tam) -> T2 Phase 4 -> T3 Phase 3 -> T4 Phase 2 -> T5 Phase 1.
// Chay lien tiep khong reset (T6: start/done noi tiep). Chay voi +HR_LAT/+HR_GAP de lam T7.
`timescale 1ns/1ps
`include "gemm_defs.vh"

`define MEM_DIR "../../LeNet/training/outputs/lenet5/mem_20260930_173742_222887/"

module tb_gemm;

    localparam integer ACT_BASE = 32'h10000;
    localparam integer TIMEOUT  = 3000000;   // chu ky / phase

    // ---------------- DUT ----------------
    reg         clk = 1'b0;
    reg         rst_n = 1'b0;
    reg  [2:0]  phase = 3'd0;
    reg         start = 1'b0;
    wire        done;
    wire        hr_req, hr_ack, hr_rvalid;
    wire [23:0] hr_addr;
    wire [15:0] hr_len;
    wire [7:0]  hr_rdata;
    reg  [`OB_AW-1:0] ob_raddr = 0;
    wire [31:0] ob_rdata;
    wire        ob_part_full, ob_part_id;

    always #10 clk = ~clk;   // 50 MHz

    gemm_core u_dut (
        .clk(clk), .rst_n(rst_n), .phase(phase), .start(start), .done(done),
        .hr_req(hr_req), .hr_addr(hr_addr), .hr_len(hr_len), .hr_ack(hr_ack),
        .hr_rdata(hr_rdata), .hr_rvalid(hr_rvalid),
        .ob_raddr(ob_raddr), .ob_rdata(ob_rdata),
        .ob_part_full(ob_part_full), .ob_part_id(ob_part_id)
    );

    hyperram_model #(
        .MEM_BYTES(131072),
        .MODEL_FILE({`MEM_DIR, "model_image.mem"}),
        .MODEL_LAST(62527)
    ) u_hr (
        .clk(clk), .rst_n(rst_n), .hr_req(hr_req), .hr_addr(hr_addr), .hr_len(hr_len),
        .hr_ack(hr_ack), .hr_rdata(hr_rdata), .hr_rvalid(hr_rvalid)
    );

    // ---------------- du lieu chuan ----------------
    reg [7:0]  w_c1 [0:149];
    reg [7:0]  w_c3 [0:2399];
    reg [7:0]  w_c5 [0:47999];
    reg [7:0]  w_f6 [0:10079];
    reg [7:0]  w_o  [0:839];
    reg [31:0] b_c1 [0:5];
    reg [31:0] b_c3 [0:15];
    reg [31:0] b_c5 [0:119];
    reg [31:0] b_f6 [0:83];
    reg [31:0] b_o  [0:9];
    reg [7:0]  img  [0:17407];     // 17 mau x 32 x 32 (da pad)

    reg [7:0]  act  [0:19599];     // activation cua test hien tai (toi da 25 x 784)
    reg [31:0] expv [0:4703];      // ket qua chuan
    reg [31:0] got  [0:4703];      // ket qua doc tu Out_buffer

    integer seed;

    // cau hinh phase (detail.md Bang 1)
    integer cM, cK, cN, cConv, cPP, cQ;
    task cfg(input integer p);
        begin
            case (p)
                1: begin cM = 6;   cK = 25;  cN = 784; cConv = 1; cPP = 1; cQ = 1176; end
                2: begin cM = 16;  cK = 150; cN = 100; cConv = 1; cPP = 1; cQ = 400;  end
                3: begin cM = 120; cK = 400; cN = 1;   cConv = 0; cPP = 0; cQ = 0;    end
                4: begin cM = 84;  cK = 120; cN = 1;   cConv = 0; cPP = 0; cQ = 0;    end
                default: begin cM = 10; cK = 84; cN = 1; cConv = 0; cPP = 0; cQ = 0; end
            endcase
        end
    endtask

    // weight W[m][k] co dau (layout OIHW / [out][in] -> chi so m*K + k)
    function integer wgt(input integer p, input integer idx);
        begin
            case (p)
                1: wgt = $signed(w_c1[idx]);
                2: wgt = $signed(w_c3[idx]);
                3: wgt = $signed(w_c5[idx]);
                4: wgt = $signed(w_f6[idx]);
                default: wgt = $signed(w_o[idx]);
            endcase
        end
    endfunction

    function integer bia(input integer p, input integer m);
        begin
            case (p)
                1: bia = b_c1[m];
                2: bia = b_c3[m];
                3: bia = b_c5[m];
                4: bia = b_f6[m];
                default: bia = b_o[m];
            endcase
        end
    endfunction

    // Tao activation. mode 0: ngau nhien 0..val, 1: hang so val, 2: im2col anh mau val (Phase 1)
    task load_act(input integer mode, input integer val);
        integer i, k, n, ky, kx, oy, ox;
        begin
            for (i = 0; i < cK * cN; i = i + 1) begin
                case (mode)
                    0: act[i] = $unsigned($random(seed)) % (val + 1);
                    1: act[i] = val;
                    default: begin
                        // P1[k][n]: k = ky*5 + kx, n = oy*28 + ox, X[oy+ky][ox+kx] (GD4)
                        k  = i / cN;  n  = i % cN;
                        ky = k / 5;   kx = k % 5;
                        oy = n / 28;  ox = n % 28;
                        act[i] = img[val * 1024 + (oy + ky) * 32 + (ox + kx)];
                    end
                endcase
                u_hr.mem[ACT_BASE + i] = act[i];
            end
        end
    endtask

    // exp[m*N + n] = B[m] + sum_k W[m][k] * P[k][n]   (P khong dau, GD12; INT32 wrap, GD13)
    task compute_golden(input integer p);
        integer m, n, k, acc;
        begin
            for (m = 0; m < cM; m = m + 1)
                for (n = 0; n < cN; n = n + 1) begin
                    acc = bia(p, m);
                    for (k = 0; k < cK; k = k + 1)
                        acc = acc + wgt(p, m * cK + k) * act[k * cN + n];
                    expv[m * cN + n] = acc;
                end
        end
    endtask

    // Doc cnt word tu Out_buffer (dia chi base..), luu vao got[lin0..]. Cong doc tre 1 clk.
    task automatic read_ob(input integer base, input integer cnt, input integer lin0);
        integer i;
        begin
            for (i = 0; i <= cnt; i = i + 1) begin
                @(negedge clk);
                if (i > 0)   got[lin0 + i - 1] = ob_rdata;
                if (i < cnt) ob_raddr = base + i;
            end
        end
    endtask

    // ---------------- giam sat ----------------
    integer n_clear, n_tick, n_save, n_part_seen, n_part_read, n_done_rise, n_part_id_err;
    reg     done_d = 1'b0;

    always @(posedge clk) begin
        if (u_dut.clear) n_clear = n_clear + 1;
        if (u_dut.tick)  n_tick  = n_tick  + 1;
        if (u_dut.save)  n_save  = n_save  + 1;
        if (ob_part_full) n_part_seen = n_part_seen + 1;
        if (done && !done_d) n_done_rise = n_done_rise + 1;
        done_d = done;
    end

    // Module sau gia lap: doc 1/4 output ngay khi phan vung day (Phase 1, 2)
    reg     rd_en_pp = 1'b0;
    integer rd_q = 0;
    always begin
        @(posedge clk);
        if (ob_part_full && rd_en_pp) begin
            if (ob_part_id !== (n_part_read % 2)) begin
                $display("[TB][ERROR] part_id = %0d, ky vong %0d", ob_part_id, n_part_read % 2);
                n_part_id_err = n_part_id_err + 1;
            end
            read_ob(ob_part_id * rd_q, rd_q, n_part_read * rd_q);
            n_part_read = n_part_read + 1;
        end
    end

    // ---------------- chay 1 test ----------------
    integer tests_run = 0, tests_fail = 0;

    task run_phase(input integer p, input [8*56-1:0] name, input integer inject);
        integer i, cyc, total, nerr, nblk, ngrp, perr, hr_err0, wcyc;
        begin
            cfg(p);
            total = cM * cN;
            compute_golden(p);
            for (i = 0; i < 4704; i = i + 1) got[i] = 32'hDEADBEEF;
            n_clear = 0; n_tick = 0; n_save = 0; n_part_seen = 0; n_part_read = 0;
            n_done_rise = 0; n_part_id_err = 0;
            hr_err0  = u_hr.err_cnt;
            rd_q     = cQ;
            rd_en_pp = cPP;
            perr     = 0;

            @(negedge clk); phase = p; start = 1'b1;
            @(negedge clk); start = 1'b0;
            if (done !== 1'b0) begin
                $display("[TB][ERROR] done khong ve 0 sau start");
                perr = perr + 1;
            end

            cyc = 0;
            while (done !== 1'b1 && cyc < TIMEOUT) begin
                @(negedge clk);
                cyc = cyc + 1;
                // T6 phu: xung start sai luc dang ban -> phai bi bo qua (GD16)
                if (inject && cyc == 2000) begin
                    phase = 3'd3; start = 1'b1;
                    @(negedge clk);
                    start = 1'b0; phase = p;
                    cyc = cyc + 1;
                end
            end
            if (cyc >= TIMEOUT) begin
                $display("[TB][ERROR] TIMEOUT sau %0d chu ky", cyc);
                perr = perr + 1;
            end

            if (cPP) begin
                wcyc = 0;
                while (n_part_read < 4 && wcyc < 20000) begin @(negedge clk); wcyc = wcyc + 1; end
            end else begin
                read_ob(0, total, 0);
            end
            rd_en_pp = 1'b0;

            // so tung phan tu
            nerr = 0;
            for (i = 0; i < total; i = i + 1) begin
                if (got[i] !== expv[i]) begin
                    if (nerr < 10)
                        $display("    sai: m=%0d n=%0d  got=%0d  exp=%0d", i / cN, i % cN,
                                 $signed(got[i]), $signed(expv[i]));
                    nerr = nerr + 1;
                end
            end

            // kiem giao thuc
            nblk = cConv ? cM * ((cN + 15) / 16) : (cM + 15) / 16;
            ngrp = (cK + 3) / 4;
            if (n_clear != nblk)        begin $display("    clear: %0d, ky vong %0d", n_clear, nblk);        perr = perr + 1; end
            if (n_tick  != nblk * ngrp) begin $display("    tick : %0d, ky vong %0d", n_tick, nblk * ngrp);  perr = perr + 1; end
            if (n_save  != total)       begin $display("    save : %0d, ky vong %0d", n_save, total);        perr = perr + 1; end
            if (n_done_rise != 1)       begin $display("    done len %0d lan, ky vong 1", n_done_rise);      perr = perr + 1; end
            if (cPP && (n_part_seen != 4 || n_part_read != 4)) begin
                $display("    part_full: thay %0d, doc %0d, ky vong 4", n_part_seen, n_part_read);
                perr = perr + 1;
            end
            if (!cPP && n_part_seen != 0) begin $display("    part_full khong duoc len o Direct"); perr = perr + 1; end
            if (n_part_id_err != 0) perr = perr + 1;
            if (u_hr.err_cnt != hr_err0) begin $display("    HyperRAM bao %0d burst sai", u_hr.err_cnt - hr_err0); perr = perr + 1; end

            tests_run = tests_run + 1;
            if (nerr == 0 && perr == 0)
                $display("[PASS] %0s : %0d/%0d phan tu dung, %0d chu ky", name, total, total, cyc);
            else begin
                $display("[FAIL] %0s : %0d/%0d phan tu sai, %0d loi giao thuc", name, nerr, total, perr);
                tests_fail = tests_fail + 1;
            end
        end
    endtask

    // ---------------- kich ban ----------------
    initial begin
        if (!$value$plusargs("SEED=%d", seed)) seed = 1;
        $readmemh({`MEM_DIR, "c1_weight.mem"},     w_c1);
        $readmemh({`MEM_DIR, "c3_weight.mem"},     w_c3);
        $readmemh({`MEM_DIR, "c5_weight.mem"},     w_c5);
        $readmemh({`MEM_DIR, "f6_weight.mem"},     w_f6);
        $readmemh({`MEM_DIR, "output_weight.mem"}, w_o);
        $readmemh({`MEM_DIR, "c1_bias.mem"},       b_c1);
        $readmemh({`MEM_DIR, "c3_bias.mem"},       b_c3);
        $readmemh({`MEM_DIR, "c5_bias.mem"},       b_c5);
        $readmemh({`MEM_DIR, "f6_bias.mem"},       b_f6);
        $readmemh({`MEM_DIR, "output_bias.mem"},   b_o);
        $readmemh({`MEM_DIR, "reference_padded_input.mem"}, img);

        repeat (5) @(negedge clk);
        rst_n = 1'b1;
        repeat (5) @(negedge clk);

        // T1: Phase 5 (M=10, K=84, N=1), W5/B5 that
        cfg(5); load_act(0, 127); run_phase(5, "T1a Phase5 H4 ngau nhien 0..127", 0);
        cfg(5); load_act(1, 127); run_phase(5, "T1b Phase5 H4 toan 127", 0);
        cfg(5); load_act(1, 0);   run_phase(5, "T1c Phase5 H4 toan 0 (ra dung bias)", 0);
        // T2, T3: Phase 4, Phase 3
        cfg(4); load_act(0, 127); run_phase(4, "T2  Phase4 H3 ngau nhien", 0);
        cfg(3); load_act(0, 127); run_phase(3, "T3  Phase3 V ngau nhien", 0);
        // T4: Phase 2 (co xung start gia luc dang ban)
        cfg(2); load_act(0, 127); run_phase(2, "T4  Phase2 P2 ngau nhien + start gia", 1);
        // T5: Phase 1
        cfg(1); load_act(2, 0);   run_phase(1, "T5a Phase1 P1 = im2col anh that (mau 0)", 0);
        cfg(1); load_act(0, 255); run_phase(1, "T5b Phase1 P1 ngau nhien 0..255", 0);
        cfg(1); load_act(1, 255); run_phase(1, "T5c Phase1 P1 toan 255 (kiem UINT8)", 0);
        // T6: chay lai Phase 5 ngay sau Phase 1 (doi che do Conv -> FC)
        cfg(5); load_act(0, 127); run_phase(5, "T6  Phase5 sau Phase1", 0);

        $display("--------------------------------------------------");
        $display("HyperRAM: %0d burst, %0d byte", u_hr.burst_cnt, u_hr.byte_cnt);
        if (tests_fail == 0) $display("KET QUA: TAT CA %0d TEST PASS", tests_run);
        else                 $display("KET QUA: %0d/%0d TEST FAIL", tests_fail, tests_run);
        $display("--------------------------------------------------");
        $finish;
    end

endmodule
