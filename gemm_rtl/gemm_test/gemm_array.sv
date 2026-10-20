//==============================================================================
// gemm_array.sv  -  16-lane MAC array (Output-Stationary datapath)
//------------------------------------------------------------------------------
// Moi lane j:  acc[j] <= acc[j] + broadcast_in * element_in[j]
//   - broadcast_in : 1 trong so w[0,i], phat chung (broadcast) cho ca 16 lane
//   - element_in[j]: p[i,j], moi lane nhan 1 pixel rieng
//   - acc[j]       : output-stationary -> ket qua nam yen trong thanh ghi
//                    cho den khi het K chu ky
//
// PIPELINE = 1 : them 1 tang thanh ghi sau bo nhan (prod_q) -> bo nhan 8x8
//                map vao DSP/MULT cua Gowin co thanh ghi ra, duong cong
//                (adder 32-bit) tach rieng. Latency them = 1 chu ky.
// PIPELINE = 0 : nhan + cong trong cung 1 chu ky.
//
// Uu tien dieu khien: clear > load_bias > enable
//==============================================================================
module gemm_array #(
  parameter int LANES    = 16,
  parameter bit PIPELINE = 1'b1
) (
  input  logic                clk,
  input  logic                rst_n,        // async, active-low
  input  logic                clear,        // sync clear accumulators
  input  logic                load_bias,    // sync load acc <= bias_in
  input  logic                enable,       // du lieu hop le o chu ky nay
  input  logic signed [31:0]  bias_in    [0:LANES-1],
  input  logic signed [7:0]   broadcast_in,
  input  logic signed [7:0]   element_in [0:LANES-1],
  output logic signed [31:0]  result_out [0:LANES-1]
);

  //----------------------------------------------------------------------------
  // Tin hieu enable cho tang cong don (tre 1 chu ky neu co pipeline)
  //----------------------------------------------------------------------------
  logic acc_en;

  generate
    if (PIPELINE) begin : g_en_pipe
      logic en_q;
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n) en_q <= 1'b0;
        else        en_q <= enable;          // canh hang voi prod_q
      end
      assign acc_en = en_q;
    end else begin : g_en_comb
      assign acc_en = enable;
    end
  endgenerate

  //----------------------------------------------------------------------------
  // 16 Processing Element
  //----------------------------------------------------------------------------
  genvar j;
  generate
    for (j = 0; j < LANES; j++) begin : g_pe
      logic signed [15:0] prod_c;   // tich to hop: int8 * int8 -> int16
      logic signed [15:0] prod_s;   // tich dua vao bo cong don
      logic signed [31:0] acc;      // thanh ghi tich luy (output-stationary)

      // Step 1: nhan co dau. Ca 2 toan hang deu signed, mo rong len 16 bit
      // -> mo rong dau len 16 bit truoc khi nhan (-128*-128 = 16384 van vua).
      assign prod_c = broadcast_in * element_in[j];

      if (PIPELINE) begin : g_pipe
        logic signed [15:0] prod_q;
        // Khong reset: gia tri chi duoc dung khi en_q = 1 (da reset)
        always_ff @(posedge clk) prod_q <= prod_c;
        assign prod_s = prod_q;
      end else begin : g_nopipe
        assign prod_s = prod_c;
      end

      // Step 2: cap nhat accumulator
      always_ff @(posedge clk or negedge rst_n) begin
        if (!rst_n)          acc <= 32'sd0;
        else if (clear)      acc <= 32'sd0;
        else if (load_bias)  acc <= bias_in[j];
        else if (acc_en)     acc <= acc + 32'(prod_s);   // sign-extend 16 -> 32
      end

      assign result_out[j] = acc;
    end
  endgenerate

endmodule
