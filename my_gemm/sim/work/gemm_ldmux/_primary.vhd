library verilog;
use verilog.vl_types.all;
entity gemm_ldmux is
    port(
        load_select     : in     vl_logic_vector(1 downto 0);
        data_phase      : in     vl_logic;
        hr_rvalid       : in     vl_logic;
        hr_rdata        : in     vl_logic_vector(7 downto 0);
        bias_we         : out    vl_logic;
        bc_we           : out    vl_logic;
        dma_we          : out    vl_logic;
        ld_data         : out    vl_logic_vector(7 downto 0)
    );
end gemm_ldmux;
