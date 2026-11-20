// =============================================================================
// gemm_engine.v  -  STEP 3: Engine GEMM tong quat, 1 lane (1 MAC / clock)
// -----------------------------------------------------------------------------
// Tinh:  Out[o][n] = f( B[o] + sum_k W[o][k] * X[k][n] )
//        f = RQ(ReLU(.)) neu DO_RQ = 1,  f = giu nguyen INT32 neu DO_RQ = 0
//
// Thuat toan (giong het tb_ref_model.v):
//   for o in 0..M-1
//     for n in 0..N-1
//       acc = B[o]
//       for k in 0..K-1:  acc += W[o*K + k] * X[k*N + n]
//       Out[o*N + n] = f(acc)
//
// Bo nho nam NGOAI engine, doc DONG BO tre 1 clock (giong BSRAM tren Gowin):
//   chu ky t : engine dua dia chi ra (to hop tu cac bo dem)
//   canh len : bo nho chot du lieu
//   chu ky t+1: du lieu co tren *_data
//
// Luong trang thai cho 1 phan tu Out[o][n]  (K + 3 clock):
//
//   clock   : S_BIAS | S_MAC k=0 | S_MAC k=1 | ... | S_MAC k=K-1 | S_DRAIN  | S_WRITE
//   dia chi : b=o    | w,x (k=0) | w,x (k=1) | ... | w,x (K-1)   |   -      |   -
//   mac     :   -    | acc=bias  | acc+=k0   | ... | acc+=k(K-2) | acc+=K-1 | (acc xong)
//   ghi     :   -    |    -      |    -      | ... |     -       |   -      | out_we=1
//
//   => mac luon xu ly du lieu cua dia chi phat ra o clock TRUOC (do tre 1 clock).
//      load_d / en_d la "co tre 1 clock" de dong bo voi du lieu tra ve.
// =============================================================================
`timescale 1ns/1ps
module gemm_engine #(
    parameter        M          = 6,
    parameter        K          = 25,
    parameter        N          = 784,
    parameter        X_UNSIGNED = 1,              // C1 = 1 (UINT8), con lai = 0
    parameter        DO_RQ      = 1,              // lop Output = 0
    parameter [22:0] MULT       = 23'd1669522
)(
    input  wire        clk,
    input  wire        rst_n,
    input  wire        start,                      // xung 1 clock de bat dau
    output wire        busy,
    output reg         done,                       // xung 1 clock khi xong
    // Doc bo nho (dia chi to hop, du lieu ve sau 1 clock)
    output wire [6:0]  b_addr,  input wire [31:0] b_data,
    output wire [15:0] w_addr,  input wire [7:0]  w_data,
    output wire [14:0] x_addr,  input wire [7:0]  x_data,
    // Ghi ket qua
    output wire        out_we,
    output wire [12:0] out_addr,
    output wire [31:0] out_data
);
    // ---------------------------------------------------------------------
    // 1. Trang thai va bo dem
    // ---------------------------------------------------------------------
    localparam [2:0] S_IDLE  = 3'd0,
                     S_BIAS  = 3'd1,
                     S_MAC   = 3'd2,
                     S_DRAIN = 3'd3,
                     S_WRITE = 3'd4,
                     S_DONE  = 3'd5;

    reg [2:0]  state;
    reg [6:0]  o;          // hang ra       0..M-1
    reg [9:0]  n;          // cot ra        0..N-1
    reg [8:0]  k;          // buoc tich luy 0..K-1
    reg [15:0] w_base;     // = o*K   (cong don K moi lan doi o, khoi can bo nhan)
    reg [14:0] x_ptr;      // = k*N + n
    reg [12:0] out_ptr;    // = o*N + n
    reg        load_d;     // tre 1 clock: bias da ve -> nap vao acc
    reg        en_d;       // tre 1 clock: w,x da ve  -> cong don

    // ---------------------------------------------------------------------
    // 2. Dia chi bo nho (to hop tu bo dem)
    // ---------------------------------------------------------------------
    assign b_addr = o;
    assign w_addr = w_base + k;
    assign x_addr = x_ptr;

    // ---------------------------------------------------------------------
    // 3. Datapath: 1 MAC + 1 ReLU/Requant
    // ---------------------------------------------------------------------
    wire signed [31:0] acc;
    wire        [7:0]  q;

    mac u_mac (
        .clk(clk), .load(load_d), .en(en_d), .bias(b_data),
        .w(w_data), .x(x_data), .x_unsigned(X_UNSIGNED[0]), .acc(acc)
    );

    relu_rq #(.MULT(MULT)) u_rq (.acc(acc), .q_out(q));

    // ---------------------------------------------------------------------
    // 4. Cong ghi ket qua
    // ---------------------------------------------------------------------
    assign out_we   = (state == S_WRITE);
    assign out_addr = out_ptr;
    assign out_data = DO_RQ ? {24'd0, q} : acc;
    assign busy     = (state != S_IDLE);

    // ---------------------------------------------------------------------
    // 5. FSM
    // ---------------------------------------------------------------------
    always @(posedge clk or negedge rst_n) begin
        if (!rst_n) begin
            state <= S_IDLE;  done <= 1'b0;
            o <= 0; n <= 0; k <= 0;
            w_base <= 0; x_ptr <= 0; out_ptr <= 0;
            load_d <= 1'b0; en_d <= 1'b0;
        end else begin
            done   <= 1'b0;
            load_d <= 1'b0;
            en_d   <= 1'b0;

            case (state)
            S_IDLE: if (start) begin
                o <= 0; n <= 0; w_base <= 0; out_ptr <= 0;
                state <= S_BIAS;
            end

            // Phat dia chi bias (b_addr = o). Clock sau bias se ve.
            S_BIAS: begin
                k      <= 0;
                x_ptr  <= n;          // k = 0 -> X[0*N + n]
                load_d <= 1'b1;       // clock sau: acc <= b_data
                state  <= S_MAC;
            end

            // Moi clock phat dia chi cua buoc k; clock sau mac cong don.
            S_MAC: begin
                en_d <= 1'b1;
                if (k == K - 1) begin
                    state <= S_DRAIN;
                end else begin
                    k     <= k + 1'b1;
                    x_ptr <= x_ptr + N;
                end
            end

            // Clock nay mac cong buoc cuoi cung (k = K-1).
            S_DRAIN: state <= S_WRITE;

            // acc da xong -> out_we = 1 trong clock nay. Chuyen sang phan tu ke.
            S_WRITE: begin
                out_ptr <= out_ptr + 1'b1;
                if (n == N - 1) begin
                    n <= 0;
                    if (o == M - 1) begin
                        state <= S_DONE;
                    end else begin
                        o      <= o + 1'b1;
                        w_base <= w_base + K;
                        state  <= S_BIAS;
                    end
                end else begin
                    n     <= n + 1'b1;
                    state <= S_BIAS;
                end
            end

            S_DONE: begin
                done  <= 1'b1;
                state <= S_IDLE;
            end

            default: state <= S_IDLE;
            endcase
        end
    end
endmodule
