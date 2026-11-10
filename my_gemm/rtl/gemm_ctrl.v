// gemm_ctrl.v - Controller (Figure 1, detail.md Timing Flow 1-5)
//
// Luong 1 phase:
//   IDLE --start--> chot phase, (M,K,N), dia chi                         (TF 1)
//   BC0      : nap broadcast lan dau (W1 / hang 0 cua W2 / V,H3,H4)       (TF 2)
//   ROW      : (Conv) dau hang m; Phase 2 kich nap ngam hang m+1 vao nua
//              Ping-Pong con lai cua broadcast buffer                      (TF 2, GD11)
//   BIAS     : nap 16 bias (Conv: B[m] / FC: B[m0..m0+15])                (GD10)
//   CLR      : clear = 1 -> acc = bias                                     (TF 3)
//   RUN      : phat K nhip MAC; dung cho neu bank element chua valid;
//              dem tick, du ceil(K/4) tick thi xong block                  (TF 4, GD8)
//   DRAIN    : cho tang cong cua GEMM array xong (pipeline 2 tang)
//   SAVE     : save = 1 + address, ghi nv lane vao Out_buffer, 1 word/clk  (TF 5, GD14)
//   NEXTB    : sang block / hang ke tiep, hoac DONE                        (GD5)
//   DONE     : done = 1 (giu toi lan start sau)                            (TF 5, GD16)
`include "gemm_defs.vh"
module gemm_ctrl #(
    parameter [23:0] C1_W  = `HR_C1_W,  C1_B  = `HR_C1_B,
    parameter [23:0] C3_W  = `HR_C3_W,  C3_B  = `HR_C3_B,
    parameter [23:0] C5_W  = `HR_C5_W,  C5_B  = `HR_C5_B,
    parameter [23:0] F6_W  = `HR_F6_W,  F6_B  = `HR_F6_B,
    parameter [23:0] OUT_W = `HR_OUT_W, OUT_B = `HR_OUT_B,
    parameter [23:0] ACT_BASE = `HR_ACT_BASE
)(
    input  wire              clk,
    input  wire              rst_n,
    input  wire              start,
    input  wire [2:0]        phase,
    output reg               done,
    // cau hinh cho datapath (giu on dinh suot phase)
    output reg               conv_mode,
    output reg  [15:0]       cfg_m,
    output reg  [15:0]       cfg_k,
    output reg  [15:0]       cfg_n,
    output reg  [23:0]       cfg_wbase,
    output reg  [23:0]       cfg_actbase,
    output reg               ob_pp,
    output reg  [`OB_AW-1:0] ob_q,
    output reg               init,
    // nap bias
    output wire              bias_req,
    output wire [23:0]       bias_addr,
    output wire [15:0]       bias_len,
    input  wire              bias_gnt,
    input  wire              bias_we,
    // nap broadcast
    output wire              bc_req,
    output wire [23:0]       bc_addr,
    output wire [15:0]       bc_len,
    input  wire              bc_gnt,
    input  wire              bc_we,
    output wire [8:0]        bc_waddr,
    // GEMM array / broadcast doc / element
    output wire              clear,
    output reg               mac_en,
    input  wire              tick,
    input  wire              busy,       // GEMM array con tich dang cho cong
    output wire [8:0]        bc_raddr,
    input  wire [1:0]        elem_valid,
    // Out_buffer
    output wire              save,
    output wire [`OB_AW-1:0] address,
    output wire [3:0]        lane_sel
);

    localparam S_IDLE  = 4'd0,  S_BC0  = 4'd1,  S_BC0W = 4'd2,  S_ROW  = 4'd3,
               S_BIAS  = 4'd4,  S_BIASW = 4'd5, S_CLR  = 4'd6,  S_RUN  = 4'd7,
               S_SAVE  = 4'd8,  S_NEXTB = 4'd9, S_DONE = 4'd10, S_DRAIN = 4'd11;

    reg [3:0]  st;

    // cau hinh them
    reg [23:0] cfg_bbase;
    reg        bc_pp;          // broadcast Ping-Pong (chi Phase 2)
    reg [15:0] bc0_len;

    wire [15:0] rows   = conv_mode ? cfg_m : 16'd1;
    wire [15:0] span   = conv_mode ? cfg_n : cfg_m;
    wire [15:0] ngroup = (cfg_k + 16'd3) >> 2;

    // bo dem
    reg [15:0] r, n0, iss_k, tick_cnt, bcnt;
    reg        iss_bank;
    reg [3:0]  lane;
    reg [`OB_AW-1:0] oaddr;
    reg [8:0]  bc_off;
    reg [23:0] bc_next_addr;   // Phase 2: dia chi hang W2 ke tiep can nap ngam

    wire [15:0] rem_n = span - n0;
    wire [4:0]  nv    = (rem_n >= 16'd16) ? 5'd16 : rem_n[4:0];

    // ---------------- loader broadcast ----------------
    localparam L_IDLE = 2'd0, L_REQ = 2'd1, L_DATA = 2'd2;
    reg [1:0]  bl_st;
    reg [23:0] bl_addr;
    reg [15:0] bl_len, bl_cnt;
    reg [8:0]  bl_dst;

    assign bc_req   = (bl_st == L_REQ);
    assign bc_addr  = bl_addr;
    assign bc_len   = bl_len;
    assign bc_waddr = bl_dst;

    // ---------------- nap bias ----------------
    assign bias_req  = (st == S_BIAS);
    assign bias_addr = cfg_bbase + {6'd0, (conv_mode ? r : n0), 2'b00};
    assign bias_len  = conv_mode ? 16'd4 : {9'd0, nv, 2'b00};

    // ---------------- MAC / Out_buffer ----------------
    wire issue = (st == S_RUN) && (iss_k < cfg_k) && elem_valid[iss_bank];

    assign clear    = (st == S_CLR);
    assign bc_raddr = bc_off + iss_k[8:0];
    assign save     = (st == S_SAVE);
    assign address  = oaddr;
    assign lane_sel = lane;

    wire [`OB_AW-1:0] ob_wrap = {ob_q[`OB_AW-2:0], 1'b0} - 1'b1;  // 2Q - 1

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= S_IDLE; done <= 1'b0; init <= 1'b0; mac_en <= 1'b0;
            conv_mode <= 1'b0; cfg_m <= 16'd0; cfg_k <= 16'd0; cfg_n <= 16'd0;
            cfg_wbase <= 24'd0; cfg_actbase <= 24'd0; cfg_bbase <= 24'd0;
            ob_pp <= 1'b0; ob_q <= {`OB_AW{1'b0}}; bc_pp <= 1'b0; bc0_len <= 16'd0;
            r <= 16'd0; n0 <= 16'd0; iss_k <= 16'd0; tick_cnt <= 16'd0; bcnt <= 16'd0;
            iss_bank <= 1'b0; lane <= 4'd0; oaddr <= {`OB_AW{1'b0}};
            bc_off <= 9'd0; bc_next_addr <= 24'd0;
            bl_st <= L_IDLE; bl_addr <= 24'd0; bl_len <= 16'd0; bl_cnt <= 16'd0; bl_dst <= 9'd0;
        end else begin
            init   <= 1'b0;
            mac_en <= issue;

            // ---- loader broadcast (chay song song voi FSM chinh) ----
            case (bl_st)
                L_REQ:  if (bc_gnt) begin bl_cnt <= 16'd0; bl_st <= L_DATA; end
                L_DATA: if (bc_we) begin
                    bl_dst <= bl_dst + 9'd1;
                    bl_cnt <= bl_cnt + 16'd1;
                    if (bl_cnt == bl_len - 16'd1) bl_st <= L_IDLE;
                end
                default: ;
            endcase

            // ---- FSM chinh ----
            case (st)
                S_IDLE: begin
                    if (start && phase >= 3'd1 && phase <= 3'd5) begin
                        done <= 1'b0;
                        init <= 1'b1;
                        cfg_actbase <= ACT_BASE;
                        case (phase)   // detail.md Bang 1
                            3'd1: begin conv_mode <= 1'b1; cfg_m <= 16'd6;   cfg_k <= 16'd25;  cfg_n <= 16'd784;
                                        cfg_wbase <= C1_W;  cfg_bbase <= C1_B;  ob_pp <= 1'b1; ob_q <= 1176;
                                        bc_pp <= 1'b0; bc0_len <= 16'd150; end
                            3'd2: begin conv_mode <= 1'b1; cfg_m <= 16'd16;  cfg_k <= 16'd150; cfg_n <= 16'd100;
                                        cfg_wbase <= C3_W;  cfg_bbase <= C3_B;  ob_pp <= 1'b1; ob_q <= 400;
                                        bc_pp <= 1'b1; bc0_len <= 16'd150; end
                            3'd3: begin conv_mode <= 1'b0; cfg_m <= 16'd120; cfg_k <= 16'd400; cfg_n <= 16'd1;
                                        cfg_wbase <= C5_W;  cfg_bbase <= C5_B;  ob_pp <= 1'b0; ob_q <= 0;
                                        bc_pp <= 1'b0; bc0_len <= 16'd400; end
                            3'd4: begin conv_mode <= 1'b0; cfg_m <= 16'd84;  cfg_k <= 16'd120; cfg_n <= 16'd1;
                                        cfg_wbase <= F6_W;  cfg_bbase <= F6_B;  ob_pp <= 1'b0; ob_q <= 0;
                                        bc_pp <= 1'b0; bc0_len <= 16'd120; end
                            default: begin conv_mode <= 1'b0; cfg_m <= 16'd10; cfg_k <= 16'd84; cfg_n <= 16'd1;
                                        cfg_wbase <= OUT_W; cfg_bbase <= OUT_B; ob_pp <= 1'b0; ob_q <= 0;
                                        bc_pp <= 1'b0; bc0_len <= 16'd84; end
                        endcase
                        r <= 16'd0; n0 <= 16'd0; iss_k <= 16'd0; iss_bank <= 1'b0;
                        oaddr <= {`OB_AW{1'b0}}; bc_off <= 9'd0;
                        st <= S_BC0;
                    end
                end

                S_BC0: begin   // cfg da on dinh tu chu ky nay
                    bl_st   <= L_REQ;
                    bl_addr <= conv_mode ? cfg_wbase : cfg_actbase;
                    bl_len  <= bc0_len;
                    bl_dst  <= 9'd0;
                    bc_next_addr <= cfg_wbase + {8'd0, cfg_k};   // hang 1 cua W2
                    st <= S_BC0W;
                end

                S_BC0W: if (bl_st == L_IDLE) st <= S_ROW;

                S_ROW: if (bl_st == L_IDLE) begin   // hang r da nap xong
                    n0 <= 16'd0;
                    if (bc_pp) begin
                        bc_off <= r[0] ? cfg_k[8:0] : 9'd0;
                        if (r + 16'd1 < rows) begin
                            bl_st   <= L_REQ;
                            bl_addr <= bc_next_addr;
                            bl_len  <= cfg_k;
                            bl_dst  <= r[0] ? 9'd0 : cfg_k[8:0];
                            bc_next_addr <= bc_next_addr + {8'd0, cfg_k};
                        end
                    end
                    st <= S_BIAS;
                end

                S_BIAS: if (bias_gnt) begin bcnt <= 16'd0; st <= S_BIASW; end

                S_BIASW: if (bias_we) begin
                    bcnt <= bcnt + 16'd1;
                    if (bcnt == bias_len - 16'd1) st <= S_CLR;
                end

                S_CLR: begin
                    iss_k    <= 16'd0;
                    tick_cnt <= 16'd0;
                    st       <= S_RUN;
                end

                S_RUN: begin
                    if (issue) begin
                        iss_k <= iss_k + 16'd1;
                        if (iss_k[1:0] == 2'b11 || iss_k == cfg_k - 16'd1)
                            iss_bank <= ~iss_bank;
                    end
                    if (tick) begin
                        tick_cnt <= tick_cnt + 16'd1;
                        if (tick_cnt == ngroup - 16'd1) begin
                            lane <= 4'd0;
                            st   <= S_DRAIN;
                        end
                    end
                end

                S_DRAIN: if (!busy) st <= S_SAVE;   // cho tich cuoi cung cong xong vao acc

                S_SAVE: begin
                    lane  <= lane + 4'd1;
                    oaddr <= (ob_pp && oaddr == ob_wrap) ? {`OB_AW{1'b0}} : oaddr + 1'b1;
                    if ({1'b0, lane} == nv - 5'd1) st <= S_NEXTB;
                end

                S_NEXTB: begin
                    if (n0 + 16'd16 < span) begin
                        n0 <= n0 + 16'd16;
                        st <= conv_mode ? S_CLR : S_BIAS;   // Conv: bias B[m] khong doi trong hang
                    end else if (r + 16'd1 < rows) begin
                        r <= r + 16'd1;
                        if (!bc_pp) bc_off <= bc_off + cfg_k[8:0];   // Phase 1: hang W1 ke tiep
                        st <= S_ROW;
                    end else begin
                        st <= S_DONE;
                    end
                end

                S_DONE: begin
                    done <= 1'b1;
                    st   <= S_IDLE;
                end

                default: st <= S_IDLE;
            endcase
        end
    end

endmodule
