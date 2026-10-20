//==============================================================================
// gemm_controller.sv  -  FSM dieu khien 1 block GEMM (K vong lap)
//------------------------------------------------------------------------------
// Chuoi trang thai (moi trang thai 1 chu ky, tru RUN = K chu ky):
//
//   IDLE --start--> CLEAR --> BIAS --> RUN (K cycles) --> DRAIN --> TICK --> IDLE
//          clear=1   load_bias=1   enable=1     (ACC_LATENCY cycles)  tick=1
//
// - ACC_LATENCY = so tang pipeline trong gemm_array (0 hoac 1). DRAIN doi du
//   lieu cuoi cung "chay het" vao accumulator, nho do khi tick=1 thi
//   result_out DA CHUA ket qua cuoi cung.
// - tick: xung 1 chu ky, dung luc ket thuc K chu ky tich luy.
// - k_length duoc chot (latch) tai thoi diem start; K = 0 -> bo qua RUN.
// - Dau ra la Moore (giai ma truc tiep tu state) -> khong glitch dang ke.
//==============================================================================
module gemm_controller #(
  parameter int ACC_LATENCY = 1
) (
  input  logic        clk,
  input  logic        rst_n,
  input  logic        start,
  input  logic [15:0] k_length,
  output logic        clear,
  output logic        load_bias,
  output logic        enable,
  output logic        tick,
  output logic        busy
);

  typedef enum logic [2:0] {
    S_IDLE  = 3'd0,
    S_CLEAR = 3'd1,
    S_BIAS  = 3'd2,
    S_RUN   = 3'd3,
    S_DRAIN = 3'd4,
    S_TICK  = 3'd5
  } state_t;

  state_t       state, next_state;
  logic [15:0]  k_reg;     // K da chot
  logic [15:0]  cnt;       // dem chu ky RUN / DRAIN

  logic run_last;          // chu ky RUN cuoi cung
  logic drain_last;        // chu ky DRAIN cuoi cung
  state_t after_run;       // trang thai ngay sau RUN

  assign run_last   = (cnt == (k_reg - 16'd1));
  assign drain_last = (cnt == 16'(ACC_LATENCY - 1));
  assign after_run  = (ACC_LATENCY > 0) ? S_DRAIN : S_TICK;

  //----------------------------------------------------------------------------
  // Next-state logic
  //----------------------------------------------------------------------------
  always_comb begin
    next_state = state;
    unique case (state)
      S_IDLE:  if (start) next_state = S_CLEAR;
      S_CLEAR: next_state = S_BIAS;
      S_BIAS:  next_state = (k_reg == 16'd0) ? after_run : S_RUN;
      S_RUN:   if (run_last)   next_state = after_run;
      S_DRAIN: if (drain_last) next_state = S_TICK;
      S_TICK:  next_state = S_IDLE;
      default: next_state = S_IDLE;
    endcase
  end

  //----------------------------------------------------------------------------
  // State / counter / K register
  //----------------------------------------------------------------------------
  always_ff @(posedge clk or negedge rst_n) begin
    if (!rst_n) begin
      state <= S_IDLE;
      k_reg <= '0;
      cnt   <= '0;
    end else begin
      state <= next_state;
      unique case (state)
        S_IDLE: begin
          cnt <= '0;
          if (start) k_reg <= k_length;           // chot K
        end
        S_RUN:   cnt <= run_last ? 16'd0 : (cnt + 16'd1);
        S_DRAIN: cnt <= cnt + 16'd1;
        default: cnt <= '0;
      endcase
    end
  end

  //----------------------------------------------------------------------------
  // Outputs (Moore)
  //----------------------------------------------------------------------------
  assign clear     = (state == S_CLEAR);
  assign load_bias = (state == S_BIAS);
  assign enable    = (state == S_RUN);
  assign tick      = (state == S_TICK);
  assign busy      = (state != S_IDLE);

endmodule
