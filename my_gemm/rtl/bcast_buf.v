// bcast_buf.v - Broadcast buffer "K INT8" (Figure 1, detail.md Bang 2, GD11)
//
// RAM 512 x 8 (dung 400 byte = lon nhat o Phase 3).
//   Phase 1      : W1[6x25] = 150 byte, Direct
//   Phase 2      : 2 nua 150 byte, Ping-Pong theo hang W2
//   Phase 3/4/5  : V / H3 / H4, Direct
// Cong ghi tu loader, cong doc dong bo (tre 1 clk) cho GEMM array.
module bcast_buf (
    input  wire       clk,
    input  wire       we,
    input  wire [8:0] waddr,
    input  wire [7:0] wdata,
    input  wire [8:0] raddr,
    output reg  [7:0] rdata
);

    reg [7:0] mem [0:511];

    always @(posedge clk) begin
        if (we) mem[waddr] <= wdata;
        rdata <= mem[raddr];
    end

endmodule
