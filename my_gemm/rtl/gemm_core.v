// gemm_core.v - Top khoi GEMM, noi day dung theo Figure 1 (detail.md, image/detail/1792328797739.png)
//
//   HYPERAM --> mux(load_select) --> 16 bias INT32 ----bias(16)-----> GEMM array --result--> Out_buffer
//                                --> K INT8 ---------broadcast-----> GEMM array      save/address ^
//                                --> DMA --> Ping-pong buffer --element(16)--> GEMM array          |
//   phase, start --> controller --clear--> GEMM array --tick--> controller ----------------------+
//                    controller --> done
//
// Port ngoai Figure 1 (clk, rst_n, hr_*, ob_*) xem GD2, GD14, GD17 trong docs/buoc1_phan_tich_spec.md.
`include "gemm_defs.vh"
module gemm_core #(
    parameter [23:0] C1_W  = `HR_C1_W,  C1_B  = `HR_C1_B,
    parameter [23:0] C3_W  = `HR_C3_W,  C3_B  = `HR_C3_B,
    parameter [23:0] C5_W  = `HR_C5_W,  C5_B  = `HR_C5_B,
    parameter [23:0] F6_W  = `HR_F6_W,  F6_B  = `HR_F6_B,
    parameter [23:0] OUT_W = `HR_OUT_W, OUT_B = `HR_OUT_B,
    parameter [23:0] ACT_BASE = `HR_ACT_BASE
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire [2:0]        phase,
    input  wire              start,
    output wire              done,
    // HyperRAM (doc burst, GD2)
    output wire              hr_req,
    output wire [23:0]       hr_addr,
    output wire [15:0]       hr_len,
    input  wire              hr_ack,
    input  wire [7:0]        hr_rdata,
    input  wire              hr_rvalid,
    // Doc Out_buffer cho module sau (GD14)
    input  wire [`OB_AW-1:0] ob_raddr,
    output wire [31:0]       ob_rdata,
    output wire              ob_part_full,
    output wire              ob_part_id
);

    // ---------------- cau hinh ----------------
    wire        conv_mode, init, ob_pp;
    wire [15:0] cfg_m, cfg_k, cfg_n;
    wire [23:0] cfg_wbase, cfg_actbase;
    wire [`OB_AW-1:0] ob_q;

    // ---------------- HyperRAM / mux ----------------
    wire        bias_req, bc_req, dma_req;
    wire [23:0] bias_addr, bc_addr, dma_addr;
    wire [15:0] bias_len, bc_len, dma_len;
    wire [2:0]  gnt;
    wire [1:0]  load_select;
    wire        data_phase;
    wire        bias_we, bc_we, dma_we;
    wire [7:0]  ld_data;

    // ---------------- datapath ----------------
    wire [8:0]   bc_waddr, bc_raddr;
    wire [7:0]   broadcast;
    wire [511:0] bias;
    wire [127:0] element;
    wire [511:0] result;
    wire [1:0]   elem_valid;
    wire         clear, mac_en, tick, busy;
    wire         save;
    wire [`OB_AW-1:0] address;
    wire [3:0]   lane_sel;

    wire         e_wr_en, e_wr_bank, e_fill_done;
    wire [1:0]   e_wr_step;
    wire [3:0]   e_wr_lane;
    wire [7:0]   e_wr_data;

    gemm_ctrl #(
        .C1_W(C1_W), .C1_B(C1_B), .C3_W(C3_W), .C3_B(C3_B), .C5_W(C5_W), .C5_B(C5_B),
        .F6_W(F6_W), .F6_B(F6_B), .OUT_W(OUT_W), .OUT_B(OUT_B), .ACT_BASE(ACT_BASE)
    ) u_ctrl (
        .clk(clk), .rst_n(rst_n), .start(start), .phase(phase), .done(done),
        .conv_mode(conv_mode), .cfg_m(cfg_m), .cfg_k(cfg_k), .cfg_n(cfg_n),
        .cfg_wbase(cfg_wbase), .cfg_actbase(cfg_actbase), .ob_pp(ob_pp), .ob_q(ob_q), .init(init),
        .bias_req(bias_req), .bias_addr(bias_addr), .bias_len(bias_len),
        .bias_gnt(gnt[0]), .bias_we(bias_we),
        .bc_req(bc_req), .bc_addr(bc_addr), .bc_len(bc_len),
        .bc_gnt(gnt[1]), .bc_we(bc_we), .bc_waddr(bc_waddr),
        .clear(clear), .mac_en(mac_en), .tick(tick), .busy(busy), .bc_raddr(bc_raddr), .elem_valid(elem_valid),
        .save(save), .address(address), .lane_sel(lane_sel)
    );

    gemm_arb u_arb (
        .clk(clk), .rst_n(rst_n),
        .req({dma_req, bc_req, bias_req}),
        .addr0(bias_addr), .addr1(bc_addr), .addr2(dma_addr),
        .len0(bias_len),   .len1(bc_len),   .len2(dma_len),
        .gnt(gnt), .load_select(load_select), .data_phase(data_phase),
        .hr_req(hr_req), .hr_addr(hr_addr), .hr_len(hr_len), .hr_ack(hr_ack), .hr_rvalid(hr_rvalid)
    );

    gemm_ldmux u_mux (
        .load_select(load_select), .data_phase(data_phase),
        .hr_rvalid(hr_rvalid), .hr_rdata(hr_rdata),
        .bias_we(bias_we), .bc_we(bc_we), .dma_we(dma_we), .ld_data(ld_data)
    );

    bias_buf u_bias (
        .clk(clk), .rst_n(rst_n), .conv_mode(conv_mode),
        .ld_start(gnt[0]), .ld_we(bias_we), .ld_data(ld_data), .bias(bias)
    );

    bcast_buf u_bcast (
        .clk(clk), .we(bc_we), .waddr(bc_waddr), .wdata(ld_data),
        .raddr(bc_raddr), .rdata(broadcast)
    );

    gemm_dma u_dma (
        .clk(clk), .rst_n(rst_n), .init(init),
        .conv_mode(conv_mode), .cfg_m(cfg_m), .cfg_k(cfg_k), .cfg_n(cfg_n),
        .cfg_wbase(cfg_wbase), .cfg_actbase(cfg_actbase), .elem_valid(elem_valid),
        .dma_req(dma_req), .dma_addr(dma_addr), .dma_len(dma_len),
        .dma_gnt(gnt[2]), .dma_we(dma_we), .dma_data(ld_data),
        .wr_en(e_wr_en), .wr_bank(e_wr_bank), .wr_step(e_wr_step), .wr_lane(e_wr_lane),
        .wr_data(e_wr_data), .fill_done(e_fill_done)
    );

    elem_pingpong u_elem (
        .clk(clk), .rst_n(rst_n), .init(init),
        .wr_en(e_wr_en), .wr_bank(e_wr_bank), .wr_step(e_wr_step), .wr_lane(e_wr_lane),
        .wr_data(e_wr_data), .fill_done(e_fill_done), .valid(elem_valid),
        .mac_en(mac_en), .tick(tick), .element(element)
    );

    gemm_array u_array (
        .clk(clk), .rst_n(rst_n), .conv_mode(conv_mode), .k_len(cfg_k),
        .clear(clear), .en(mac_en), .broadcast(broadcast), .element(element),
        .bias(bias), .tick(tick), .busy(busy), .result(result)
    );

    out_buffer u_out (
        .clk(clk), .rst_n(rst_n), .pp_mode(ob_pp), .q_words(ob_q),
        .save(save), .address(address), .wdata(result[{lane_sel, 5'b00000} +: 32]),
        .part_full(ob_part_full), .part_id(ob_part_id),
        .raddr(ob_raddr), .rdata(ob_rdata)
    );

endmodule
