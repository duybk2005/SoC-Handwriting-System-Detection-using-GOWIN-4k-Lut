// mac_fc.v — Khối MAC cho FC1 (Pha 2) và FC2 (Pha 4)
// ----------------------------------------------------------------------------
// Chạy ở miền clk_sys, đọc PARAM RAM qua 1 cổng đọc (dữ liệu có sau 1 chu kỳ).
// 1 lane, tuần tự, 4 chu kỳ / phép nhân-cộng: đọc W -> đọc X -> nhân -> cộng.
//
//   FC1 (layer = 0): với j = 0..15:  acc = B1[j];  acc += image[i] * W1[j][i], i = 0..783
//                    -> ghi Acc1[j]   (res_idx = j)
//   FC2 (layer = 1): với k = 0..9 :  acc = B2[k];  acc += hidden[j] * W2[k][j], j = 0..15
//                    -> ghi Logit[k]  (res_idx = 16 + k)
//   Cả hai lớp: đọc trọng số + bias + đầu vào từ PARAM RAM, tính, ghi kết quả lại PARAM RAM.
//
// Vị trí trong PARAM RAM (word tương đối rel, 0 = offset 0x0800 của SRAM map):
//   W1[j][i]  : byte j*784 + i          (row-major -> con trỏ byte chỉ việc tăng)
//   W2[k][j]  : byte 0x3100 + k*16 + j
//   B1[j]     : word 0xC68 + j
//   B2[k]     : word 0xC78 + k
//   image copy: word IMG_W0 + i/4       (bản sao image[784] do phần cứng ghi kèm khi MCU ghi IMAGE)
//   Hidden    : word HID_W0 + j/4       (MCU ghi qua AHB 0x0350, Hidden[j] ở byte j&3)
// ----------------------------------------------------------------------------
module mac_fc #(
    parameter [11:0] IMG_W0 = 12'd3204,
    parameter [11:0] HID_W0 = 12'd3544
)(
    input  wire         clk,            // clk_sys
    input  wire         rst_n,

    input  wire         start_tgl,
    input  wire         layer,          // 0 = FC1, 1 = FC2
    output reg          done_tgl,
    output wire         busy,

    // đọc PARAM RAM (word tương đối), dữ liệu có sau 1 chu kỳ
    output reg  [11:0]  p_addr,
    input  wire [31:0]  p_rdata,

    // ghi kết quả
    output reg          res_we,
    output reg  [4:0]   res_idx,
    output reg  [31:0]  res_data
);

localparam S_IDLE = 3'd0, S_BRD = 3'd1, S_BLD = 3'd2, S_WRD = 3'd3,
           S_XRD  = 3'd4, S_MLD = 3'd5, S_ACC = 3'd6, S_WR  = 3'd7;

reg [2:0] st_s;
always @(posedge clk or negedge rst_n)
    if (!rst_n) st_s <= 3'd0;
    else        st_s <= {st_s[1:0], start_tgl};
wire start = st_s[2] ^ st_s[1];

reg  [2:0]  state;
reg         fc2;
reg  [4:0]  n;
reg  [9:0]  i;
reg  [13:0] wptr;               // byte offset của trọng số hiện tại
reg  [1:0]  wsel, xsel;
reg  [7:0]  w_q;                // trọng số đã chốt
reg  signed [31:0] acc;
reg  signed [16:0] prod;

assign busy = (state != S_IDLE);

wire [4:0] n_last = fc2 ? 5'd9   : 5'd15;
wire [9:0] i_last = fc2 ? 10'd15 : 10'd783;

always @(*) begin
    case (state)
        S_BRD:   p_addr = fc2 ? (12'hC78 + {7'd0, n}) : (12'hC68 + {7'd0, n});
        S_XRD:   p_addr = fc2 ? (HID_W0 + {10'd0, i[3:2]}) : (IMG_W0 + {4'd0, i[9:2]});
        default: p_addr = wptr[13:2];
    endcase
end

wire [7:0] rd_w = (wsel == 2'd0) ? p_rdata[7:0]   :
                  (wsel == 2'd1) ? p_rdata[15:8]  :
                  (wsel == 2'd2) ? p_rdata[23:16] : p_rdata[31:24];
wire [7:0] x_byte = (xsel == 2'd0) ? p_rdata[7:0]   :     // pixel (FC1) hoặc Hidden (FC2)
                    (xsel == 2'd1) ? p_rdata[15:8]  :
                    (xsel == 2'd2) ? p_rdata[23:16] : p_rdata[31:24];

always @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
        state <= S_IDLE; fc2 <= 1'b0; n <= 5'd0; i <= 10'd0; wptr <= 14'd0;
        wsel <= 2'd0; xsel <= 2'd0; w_q <= 8'd0; acc <= 32'sd0; prod <= 17'sd0;
        res_we <= 1'b0; res_idx <= 5'd0; res_data <= 32'd0; done_tgl <= 1'b0;
    end else begin
        res_we <= 1'b0;
        case (state)
            S_IDLE: if (start) begin
                fc2   <= layer;
                n     <= 5'd0;
                wptr  <= layer ? 14'h3100 : 14'h0000;
                state <= S_BRD;
            end
            S_BRD: state <= S_BLD;                  // đang đọc bias
            S_BLD: begin
                acc   <= $signed(p_rdata);
                i     <= 10'd0;
                state <= S_WRD;
            end
            S_WRD: begin                            // đang đọc word trọng số
                wsel  <= wptr[1:0];
                state <= S_XRD;
            end
            S_XRD: begin                            // trọng số đã có; đang đọc word ảnh
                w_q   <= rd_w;
                xsel  <= i[1:0];
                state <= S_MLD;
            end
            S_MLD: begin
                prod  <= $signed({1'b0, x_byte}) * $signed(w_q);
                state <= S_ACC;
            end
            S_ACC: begin
                acc   <= acc + {{15{prod[16]}}, prod};
                wptr  <= wptr + 14'd1;
                if (i == i_last) state <= S_WR;
                else begin
                    i     <= i + 10'd1;
                    state <= S_WRD;
                end
            end
            S_WR: begin
                res_we   <= 1'b1;
                res_idx  <= fc2 ? (5'd16 + n) : n;
                res_data <= acc;
                if (n == n_last) begin
                    done_tgl <= ~done_tgl;
                    state    <= S_IDLE;
                end else begin
                    n     <= n + 5'd1;
                    state <= S_BRD;
                end
            end
            default: state <= S_IDLE;
        endcase
    end
end

endmodule
