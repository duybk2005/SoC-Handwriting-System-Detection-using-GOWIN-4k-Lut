// gemm_arb.v - Phan xu 1 cong HyperRAM, sinh load_select (thuoc controller trong Figure 1; GD2, GD18)
//
// 3 nguon yeu cau: 0 = bias, 1 = broadcast, 2 = element (DMA). Uu tien 0 > 1 > 2.
// Giao thuc HyperRAM (GD2):
//   - hr_req = 1 kem hr_addr, hr_len giu on dinh toi khi hr_ack = 1 (1 clk).
//   - Sau do HyperRAM tra dung hr_len byte, moi byte co hr_rvalid = 1 (co the ngat quang).
//     Byte dau tien den sau chu ky hr_ack it nhat 1 clk.
//   - Chi 1 burst dang cho tai 1 thoi diem.
// Ben yeu cau giu req toi khi thay gnt (1 clk), sau do tu dem so byte cua minh.
module gemm_arb (
    input  wire         clk,
    input  wire         rst_n,
    input  wire [2:0]   req,
    input  wire [23:0]  addr0, addr1, addr2,
    input  wire [15:0]  len0,  len1,  len2,
    output wire [2:0]   gnt,
    output reg  [1:0]   load_select,
    output wire         data_phase,
    // HyperRAM
    output wire         hr_req,
    output reg  [23:0]  hr_addr,
    output reg  [15:0]  hr_len,
    input  wire         hr_ack,
    input  wire         hr_rvalid
);

    localparam A_IDLE = 2'd0, A_REQ = 2'd1, A_DATA = 2'd2;
    reg [1:0]  st;
    reg [15:0] remain;

    always @(*) begin
        case (load_select)
            2'd0:    begin hr_addr = addr0; hr_len = len0; end
            2'd1:    begin hr_addr = addr1; hr_len = len1; end
            default: begin hr_addr = addr2; hr_len = len2; end
        endcase
    end

    assign hr_req     = (st == A_REQ);
    assign data_phase = (st == A_DATA);
    assign gnt        = (st == A_REQ && hr_ack) ? (3'b001 << load_select) : 3'b000;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st          <= A_IDLE;
            load_select <= 2'd0;
            remain      <= 16'd0;
        end else begin
            case (st)
                A_IDLE: begin
                    if (req[0])      begin load_select <= 2'd0; st <= A_REQ; end
                    else if (req[1]) begin load_select <= 2'd1; st <= A_REQ; end
                    else if (req[2]) begin load_select <= 2'd2; st <= A_REQ; end
                end
                A_REQ: begin
                    if (hr_ack) begin
                        remain <= hr_len;
                        st     <= A_DATA;
                    end
                end
                A_DATA: begin
                    if (hr_rvalid) begin
                        remain <= remain - 16'd1;
                        if (remain == 16'd1) st <= A_IDLE;
                    end
                end
                default: st <= A_IDLE;
            endcase
        end
    end

endmodule
