// elem_pingpong.v - Element buffer Ping-Pong, n = 4 (detail.md Bang 1, Bang 2, GT2; GD6, GD8)
//
// 2 bank x 4 nhip x 16 lane x 8 bit = 128 byte.
// Moi lane la 1 mang nho 8 x 8 bit (dia chi = {bank, step}), ghi dong bo, doc to hop.
// (Gowin V1.9.11 tong hop thanh 1024 flip-flop; van vua GW1NSR-4C.)
// - Phia ghi (DMA): ghi tung byte; fill_done danh dau bank wr_bank da day (valid = 1).
// - Phia doc (GEMM array): element = 16 byte cua {rd_bank, rd_step}.
//   rd_step tang moi nhip MAC (mac_en); tick tra bank dang doc ve cho DMA (valid = 0)
//   va doi sang bank kia (Ping <-> Pong).
// Lane / nhip chua tung ghi co gia tri khong xac dinh; khong anh huong ket qua vi
// GEMM array chi chay dung K nhip va controller chi luu lane hop le (GD7).
module elem_pingpong (
    input  wire         clk,
    input  wire         rst_n,
    input  wire         init,       // dau phase: xoa valid, dua con tro ve bank 0
    // ghi tu DMA
    input  wire         wr_en,
    input  wire         wr_bank,
    input  wire [1:0]   wr_step,
    input  wire [3:0]   wr_lane,
    input  wire [7:0]   wr_data,
    input  wire         fill_done,
    output reg  [1:0]   valid,
    // doc cho GEMM array
    input  wire         mac_en,
    input  wire         tick,
    output wire [127:0] element
);

    reg       rd_bank;
    reg [1:0] rd_step;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            valid   <= 2'b00;
            rd_bank <= 1'b0;
            rd_step <= 2'b00;
        end else if (init) begin
            valid   <= 2'b00;
            rd_bank <= 1'b0;
            rd_step <= 2'b00;
        end else begin
            if (fill_done) valid[wr_bank] <= 1'b1;
            if (tick) begin
                valid[rd_bank] <= 1'b0;
                rd_bank        <= ~rd_bank;
                rd_step        <= 2'b00;
            end else if (mac_en) begin
                rd_step <= rd_step + 2'b01;
            end
        end
    end

    genvar l;
    generate
        for (l = 0; l < 16; l = l + 1) begin : lane
            reg  [7:0] mem [0:7];
            wire [3:0] lane_idx = l;
            always @(posedge clk) begin
                if (wr_en && wr_lane == lane_idx) mem[{wr_bank, wr_step}] <= wr_data;
            end
            assign element[l*8 +: 8] = mem[{rd_bank, rd_step}];
        end
    endgenerate

endmodule
