// gemm_dma.v - DMA nap Element buffer (Figure 1; GD4, GD5, GD7, GD8)
//
// Chay doc lap suot 1 phase, theo dung thu tu ma GEMM array tieu thu:
//   for r (hang: Conv = M, FC = 1)
//     for block (16 cot Conv / 16 hang FC)
//       for group g (4 nhip k = 4g..4g+3)
//         cho bank fill_bank trong (valid = 0), nap day, fill_done, doi bank
//
// Conv: 1 group = gl burst, moi burst = P[k, n0..n0+nv-1]  (nv byte lien tiep)
//       dia chi = act_base + k*N + n0           -> byte j vao {bank, step = k-4g, lane = j}
// FC  : 1 group = nv burst, moi burst = W[m, 4g..4g+gl-1]  (gl byte lien tiep)
//       dia chi = w_base + m*K + 4g             -> byte j vao {bank, step = j, lane = m-m0}
// (gl = min(4, K-4g), nv = min(16, so cot/hang con lai)). Lane / nhip ngoai ma tran
// khong doc tu HyperRAM; gia tri cu trong buffer khong anh huong vi khong duoc luu ra.
// Dia chi tinh bang bo cong tich luy, khong dung bo nhan.
module gemm_dma (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         init,
    input  wire         conv_mode,
    input  wire [15:0]  cfg_m,
    input  wire [15:0]  cfg_k,
    input  wire [15:0]  cfg_n,
    input  wire [23:0]  cfg_wbase,
    input  wire [23:0]  cfg_actbase,
    input  wire [1:0]   elem_valid,
    // yeu cau HyperRAM (qua arbiter)
    output wire         dma_req,
    output wire [23:0]  dma_addr,
    output wire [15:0]  dma_len,
    input  wire         dma_gnt,
    input  wire         dma_we,
    input  wire [7:0]   dma_data,
    // ghi vao Element buffer
    output wire         wr_en,
    output wire         wr_bank,
    output wire [1:0]   wr_step,
    output wire [3:0]   wr_lane,
    output wire [7:0]   wr_data,
    output wire         fill_done
);

    localparam D_IDLE = 3'd0, D_WAIT = 3'd1, D_REQ = 3'd2, D_DATA = 3'd3, D_NEXT = 3'd4;

    reg [2:0]  st;
    reg [15:0] r;          // hang hien tai (Conv)
    reg [15:0] n0;         // chi so dau block (cot Conv / hang FC)
    reg [15:0] k0;         // nhip dau group
    reg [4:0]  sub;        // burst thu may trong group
    reg [4:0]  j;          // byte thu may trong burst
    reg        fill_bank;
    reg [23:0] kaddr;      // Conv: act_base + k*N
    reg [23:0] blk_base;   // FC  : w_base + m0*K
    reg [23:0] laddr;      // FC  : w_base + m*K + 4g

    wire [15:0] rows  = conv_mode ? cfg_m : 16'd1;
    wire [15:0] span  = conv_mode ? cfg_n : cfg_m;
    wire [15:0] rem_n = span - n0;
    wire [15:0] rem_k = cfg_k - k0;

    // nv, gl duoc chot vao thanh ghi (giam duong to hop dai). n0, k0 chi doi o D_NEXT
    // va luon di qua D_WAIT it nhat 1 clk truoc khi dung, nen gia tri chot luon kip.
    reg  [4:0]  nv;
    reg  [2:0]  gl;
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            nv <= 5'd0;
            gl <= 3'd0;
        end else begin
            nv <= (rem_n >= 16'd16) ? 5'd16 : rem_n[4:0];
            gl <= (rem_k >= 16'd4)  ? 3'd4  : rem_k[2:0];
        end
    end

    wire [4:0]  nsub  = conv_mode ? {2'b00, gl} : nv;
    wire [4:0]  blen  = conv_mode ? nv : {2'b00, gl};
    wire        last_sub = (sub == nsub - 5'd1);

    assign dma_req  = (st == D_REQ);
    assign dma_addr = conv_mode ? (kaddr + {8'd0, n0}) : laddr;
    assign dma_len  = {11'd0, blen};

    assign wr_en     = (st == D_DATA) & dma_we;
    assign wr_bank   = fill_bank;
    assign wr_step   = conv_mode ? sub[1:0] : j[1:0];
    assign wr_lane   = conv_mode ? j[3:0]   : sub[3:0];
    assign wr_data   = dma_data;
    assign fill_done = (st == D_NEXT) & last_sub;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= D_IDLE; r <= 16'd0; n0 <= 16'd0; k0 <= 16'd0; sub <= 5'd0; j <= 5'd0;
            fill_bank <= 1'b0; kaddr <= 24'd0; blk_base <= 24'd0; laddr <= 24'd0;
        end else if (init) begin
            st <= D_WAIT; r <= 16'd0; n0 <= 16'd0; k0 <= 16'd0; sub <= 5'd0; j <= 5'd0;
            fill_bank <= 1'b0;
            kaddr     <= cfg_actbase;
            blk_base  <= cfg_wbase;
            laddr     <= cfg_wbase;
        end else begin
            case (st)
                D_WAIT: if (!elem_valid[fill_bank]) st <= D_REQ;

                D_REQ: if (dma_gnt) begin j <= 5'd0; st <= D_DATA; end

                D_DATA: if (dma_we) begin
                    j <= j + 5'd1;
                    if (j == blen - 5'd1) st <= D_NEXT;
                end

                D_NEXT: begin
                    // xong 1 burst: sang k ke tiep (Conv) / hang m ke tiep (FC)
                    kaddr <= kaddr + {8'd0, cfg_n};
                    laddr <= laddr + {8'd0, cfg_k};
                    if (!last_sub) begin
                        sub <= sub + 5'd1;
                        st  <= D_REQ;
                    end else begin
                        // xong 1 group (bank day)
                        sub       <= 5'd0;
                        fill_bank <= ~fill_bank;
                        st        <= D_WAIT;
                        if (k0 + 16'd4 < cfg_k) begin
                            k0    <= k0 + 16'd4;
                            laddr <= blk_base + {8'd0, k0} + 24'd4;
                        end else begin
                            // xong 1 block
                            k0 <= 16'd0;
                            if (n0 + 16'd16 < span) begin
                                n0       <= n0 + 16'd16;
                                kaddr    <= cfg_actbase;
                                blk_base <= blk_base + {4'd0, cfg_k, 4'd0};
                                laddr    <= blk_base + {4'd0, cfg_k, 4'd0};
                            end else begin
                                n0    <= 16'd0;
                                kaddr <= cfg_actbase;
                                if (r + 16'd1 < rows) r <= r + 16'd1;
                                else                  st <= D_IDLE;   // het phase
                            end
                        end
                    end
                end

                default: ;  // D_IDLE: cho init
            endcase
        end
    end

endmodule
