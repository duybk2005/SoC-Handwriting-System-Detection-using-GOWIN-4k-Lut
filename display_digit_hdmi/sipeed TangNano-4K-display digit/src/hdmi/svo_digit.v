`timescale 1ns / 1ps
`include "svo_defines.vh"

// Thay the svo_tcard: ve 1 chu so kieu LED 7 doan tu ngo vao one-hot 10 bit.
// Giao tiep AXI-stream giong het svo_tcard nen chi can thay instance.
module svo_digit #(
	`SVO_DEFAULT_PARAMS,
	parameter AUTO_TEST = 0      // 1: tu dem 0..9 moi ~1s (khong can chan ngoai); 0: dung digit_in
) (
	input clk, resetn,

	input [9:0] digit_in,        // one-hot: bit k = 1 -> so k

	output reg out_axis_tvalid,
	input out_axis_tready,
	output reg [SVO_BITS_PER_PIXEL-1:0] out_axis_tdata,
	output reg [0:0] out_axis_tuser
);
	`SVO_DECLS

	// ---------- vi tri / kich thuoc chu so (tu can theo do phan giai) ----------
	localparam W  = SVO_HOR_PIXELS / 4;          // rong
	localparam H  = SVO_VER_PIXELS / 2;          // cao
	localparam T  = W / 5;                       // day net
	localparam X0 = (SVO_HOR_PIXELS - W) / 2;    // goc tren trai (giua man hinh)
	localparam Y0 = (SVO_VER_PIXELS - H) / 2;

	// ---------- 1. dong bo ngo vao (digit_in la tin hieu ngoai, khong cung clock) ----------
	reg [9:0] d_s1, d_s2;
	always @(posedge clk) begin
		d_s1 <= digit_in;
		d_s2 <= d_s1;
	end

	// ---------- che do tu test: dem 0..9 ----------
	reg [24:0] tmr;
	reg [3:0]  auto_n;
	always @(posedge clk) begin
		if (!resetn) begin
			tmr <= 0;
			auto_n <= 0;
		end else if (tmr == 25_000_000 - 1) begin
			tmr <= 0;
			auto_n <= (auto_n == 9) ? 4'd0 : auto_n + 4'd1;
		end else
			tmr <= tmr + 1;
	end

	wire [9:0] din_sel = AUTO_TEST ? (10'b1 << auto_n) : d_s2;

	// ---------- 2. decoder one-hot -> 7 doan {g,f,e,d,c,b,a} ----------
	reg [6:0] seg;
	always @(*) begin
		case (din_sel)
			10'b0000000001: seg = 7'b0111111; // 0
			10'b0000000010: seg = 7'b0000110; // 1
			10'b0000000100: seg = 7'b1011011; // 2
			10'b0000001000: seg = 7'b1001111; // 3
			10'b0000010000: seg = 7'b1100110; // 4
			10'b0000100000: seg = 7'b1101101; // 5
			10'b0001000000: seg = 7'b1111101; // 6
			10'b0010000000: seg = 7'b0000111; // 7
			10'b0100000000: seg = 7'b1111111; // 8
			10'b1000000000: seg = 7'b1101111; // 9
			default:        seg = 7'b1000000; // khong hop le -> chi hien gach ngang
		endcase
	end

	// ---------- 3. bo dem pixel (giong svo_tcard) ----------
	reg [`SVO_XYBITS-1:0] hcursor;
	reg [`SVO_XYBITS-1:0] vcursor;

	wire [`SVO_XYBITS-1:0] xr = hcursor - X0;
	wire [`SVO_XYBITS-1:0] yr = vcursor - Y0;

	wire inside = (hcursor >= X0) && (hcursor < X0 + W) &&
	              (vcursor >= Y0) && (vcursor < Y0 + H);

	// 7 hinh chu nhat
	wire sa = (yr <  T);
	wire sg = (yr >= H/2 - T/2) && (yr < H/2 + T/2);
	wire sd = (yr >= H - T);
	wire sf = (xr <  T)     && (yr <  H/2);
	wire se = (xr <  T)     && (yr >= H/2);
	wire sb = (xr >= W - T) && (yr <  H/2);
	wire sc = (xr >= W - T) && (yr >= H/2);

	wire on = inside & ((seg[0] & sa) | (seg[1] & sb) | (seg[2] & sc) |
	                    (seg[3] & sd) | (seg[4] & se) | (seg[5] & sf) |
	                    (seg[6] & sg));

	always @(posedge clk) begin
		if (!resetn) begin
			hcursor <= 0;
			vcursor <= 0;
			out_axis_tvalid <= 0;
			out_axis_tdata <= 0;
			out_axis_tuser <= 0;
		end else
		if (!out_axis_tvalid || out_axis_tready) begin
			out_axis_tvalid <= 1;
			out_axis_tdata  <= on ? {SVO_BITS_PER_PIXEL{1'b1}} : {SVO_BITS_PER_PIXEL{1'b0}}; // chu trang, nen den
			out_axis_tuser[0] <= !hcursor && !vcursor;

			if (hcursor == SVO_HOR_PIXELS-1) begin
				hcursor <= 0;
				if (vcursor == SVO_VER_PIXELS-1)
					vcursor <= 0;
				else
					vcursor <= vcursor + 1;
			end else
				hcursor <= hcursor + 1;
		end
	end
endmodule