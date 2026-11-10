// hyperram_model.v - Mo hinh HyperRAM gia lap (chi dung cho mo phong)
//
// - Mang byte MEM_BYTES. Dia chi 0..62527 nap tu model_image.mem (weight/bias that,
//   dung layout manifest.json). Phan con lai = 0; testbench ghi activation vao ACT_BASE.
// - Giao thuc doc burst (GD2):
//     hr_req = 1 (+ hr_addr, hr_len) -> model tra hr_ack = 1 trong 1 clk
//     -> cho latency ngau nhien 0..HR_LAT clk -> tra hr_len byte, moi byte co hr_rvalid = 1,
//        giua cac byte co the co chu ky trong (xac suat HR_GAP %).
// - Plusargs: +HR_LAT=<n> (mac dinh 0), +HR_GAP=<%> (mac dinh 0), +SEED=<n>.
// - Bao loi neu doc ngoai vung nho hoac hr_len = 0 (err_cnt).
`timescale 1ns/1ps
module hyperram_model #(
    parameter MEM_BYTES  = 131072,
    parameter MODEL_FILE = "model_image.mem",
    parameter MODEL_LAST = 62527
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        hr_req,
    input  wire [23:0] hr_addr,
    input  wire [15:0] hr_len,
    output reg         hr_ack,
    output reg  [7:0]  hr_rdata,
    output reg         hr_rvalid
);

    reg [7:0] mem [0:MEM_BYTES-1];

    integer lat_max, gap_pct, seed;
    integer err_cnt, burst_cnt, byte_cnt;
    integer i;

    initial begin
        for (i = 0; i < MEM_BYTES; i = i + 1) mem[i] = 8'h00;
        $readmemh(MODEL_FILE, mem, 0, MODEL_LAST);
        if (!$value$plusargs("HR_LAT=%d", lat_max)) lat_max = 0;
        if (!$value$plusargs("HR_GAP=%d", gap_pct)) gap_pct = 0;
        if (!$value$plusargs("SEED=%d",   seed))    seed    = 1;
        err_cnt = 0; burst_cnt = 0; byte_cnt = 0;
        $display("[HR] model nap %s, HR_LAT=%0d, HR_GAP=%0d%%, SEED=%0d",
                 MODEL_FILE, lat_max, gap_pct, seed);
    end

    localparam H_IDLE = 2'd0, H_ACK = 2'd1, H_LAT = 2'd2, H_DATA = 2'd3;
    reg [1:0]  st;
    reg [23:0] a;
    reg [15:0] n;
    integer    wait_cnt;

    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            st <= H_IDLE; hr_ack <= 1'b0; hr_rvalid <= 1'b0; hr_rdata <= 8'h00;
            a <= 24'd0; n <= 16'd0; wait_cnt <= 0;
        end else begin
            hr_ack    <= 1'b0;
            hr_rvalid <= 1'b0;
            case (st)
                H_IDLE: if (hr_req) begin
                    if (hr_len == 16'd0 || hr_addr + hr_len > MEM_BYTES) begin
                        $display("[HR][ERROR] %0t: burst sai addr=%0d len=%0d", $time, hr_addr, hr_len);
                        err_cnt = err_cnt + 1;
                    end
                    hr_ack <= 1'b1;
                    a      <= hr_addr;
                    n      <= hr_len;
                    burst_cnt = burst_cnt + 1;
                    st     <= H_ACK;
                end
                H_ACK: begin
                    wait_cnt <= (lat_max > 0) ? ($unsigned($random(seed)) % (lat_max + 1)) : 0;
                    st       <= H_LAT;
                end
                H_LAT: begin
                    if (wait_cnt > 0) wait_cnt <= wait_cnt - 1;
                    else              st <= H_DATA;
                end
                H_DATA: begin
                    if (gap_pct == 0 || ($unsigned($random(seed)) % 100) >= gap_pct) begin
                        hr_rvalid <= 1'b1;
                        hr_rdata  <= mem[a];
                        a         <= a + 24'd1;
                        n         <= n - 16'd1;
                        byte_cnt = byte_cnt + 1;
                        if (n == 16'd1) st <= H_IDLE;
                    end
                end
            endcase
        end
    end

endmodule
