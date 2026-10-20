//==============================================================================
// gemm_top.sv  -  Top-level: gemm_controller + gemm_array
//------------------------------------------------------------------------------
// clear / load_bias / enable cung duoc dua ra ngoai de khoi Ping-pong buffer,
// K-broadcast buffer, bias buffer va DMA biet khi nao phai day du lieu
// (du lieu phai hop le TRONG chu ky enable = 1).
// tick = 1 (1 chu ky) -> result_out hop le, MCU/DMA co the "save" vao Out_buffer.
//==============================================================================
module gemm_top #(
  parameter int LANES    = 16,
  parameter bit PIPELINE = 1'b1
) (
  input  logic                clk,
  input  logic                rst_n,
  input  logic                start,
  input  logic [15:0]         k_length,
  input  logic signed [31:0]  bias_in    [0:LANES-1],
  input  logic signed [7:0]   broadcast_in,
  input  logic signed [7:0]   element_in [0:LANES-1],
  output logic signed [31:0]  result_out [0:LANES-1],
  output logic                tick,
  output logic                clear,
  output logic                load_bias,
  output logic                enable,
  output logic                busy
);

  gemm_controller #(
    .ACC_LATENCY(PIPELINE ? 1 : 0)
  ) u_ctrl (
    .clk       (clk),
    .rst_n     (rst_n),
    .start     (start),
    .k_length  (k_length),
    .clear     (clear),
    .load_bias (load_bias),
    .enable    (enable),
    .tick      (tick),
    .busy      (busy)
  );

  gemm_array #(
    .LANES    (LANES),
    .PIPELINE (PIPELINE)
  ) u_array (
    .clk          (clk),
    .rst_n        (rst_n),
    .clear        (clear),
    .load_bias    (load_bias),
    .enable       (enable),
    .bias_in      (bias_in),
    .broadcast_in (broadcast_in),
    .element_in   (element_in),
    .result_out   (result_out)
  );

endmodule
