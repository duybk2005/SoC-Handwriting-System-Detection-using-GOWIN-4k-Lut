// gemm_ldmux.v - Mux du lieu tu HyperRAM theo load_select (Figure 1)
//   load_select = 0 -> 16 bias INT32
//   load_select = 1 -> K INT8 (broadcast buffer)
//   load_select = 2 -> DMA -> Ping-pong buffer
module gemm_ldmux (
    input  wire [1:0] load_select,
    input  wire       data_phase,
    input  wire       hr_rvalid,
    input  wire [7:0] hr_rdata,
    output wire       bias_we,
    output wire       bc_we,
    output wire       dma_we,
    output wire [7:0] ld_data
);

    wire v = data_phase & hr_rvalid;

    assign bias_we = v & (load_select == 2'd0);
    assign bc_we   = v & (load_select == 2'd1);
    assign dma_we  = v & (load_select == 2'd2);
    assign ld_data = hr_rdata;

endmodule
