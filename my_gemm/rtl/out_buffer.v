// out_buffer.v - Out_buffer INT32 (Figure 1, detail.md TF 5, Bang 2; GD14)
//
// RAM dual-port 2352 x 32.
// - Ghi: save + address (tu controller), du lieu = 1 lane cua result.
// - Phase 1, 2 (pp_mode = 1): 2 phan vung Ping-Pong, moi phan vung q_words word
//   (= 1/4 tong output). Ghi xong word cuoi cua 1 phan vung -> xung part_full
//   (tre 1 clk sau lenh ghi), part_id = 0 (Ping) / 1 (Pong).
// - Phase 3, 4, 5 (pp_mode = 0): Direct, khong phat part_full.
// - Doc: cong rieng cho module sau, tre 1 clk.
`include "gemm_defs.vh"
module out_buffer (
    input  wire                 clk,
    input  wire                 rst_n,
    input  wire                 pp_mode,
    input  wire [`OB_AW-1:0]    q_words,
    input  wire                 save,
    input  wire [`OB_AW-1:0]    address,
    input  wire [31:0]          wdata,
    output reg                  part_full,
    output reg                  part_id,
    input  wire [`OB_AW-1:0]    raddr,
    output reg  [31:0]          rdata
);

    reg [31:0] mem [0:`OB_DEPTH-1];

    always @(posedge clk) begin
        if (save) mem[address] <= wdata;
        rdata <= mem[raddr];
    end

    wire [`OB_AW-1:0] q_last  = q_words - 1'b1;
    wire [`OB_AW-1:0] q2_last = {q_words[`OB_AW-2:0], 1'b0} - 1'b1;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            part_full <= 1'b0;
            part_id   <= 1'b0;
        end else begin
            part_full <= save & pp_mode & ((address == q_last) | (address == q2_last));
            if (save & pp_mode & (address == q_last))  part_id <= 1'b0;
            if (save & pp_mode & (address == q2_last)) part_id <= 1'b1;
        end
    end

endmodule
