library verilog;
use verilog.vl_types.all;
entity gemm_dma is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        init            : in     vl_logic;
        conv_mode       : in     vl_logic;
        cfg_m           : in     vl_logic_vector(15 downto 0);
        cfg_k           : in     vl_logic_vector(15 downto 0);
        cfg_n           : in     vl_logic_vector(15 downto 0);
        cfg_wbase       : in     vl_logic_vector(23 downto 0);
        cfg_actbase     : in     vl_logic_vector(23 downto 0);
        elem_valid      : in     vl_logic_vector(1 downto 0);
        dma_req         : out    vl_logic;
        dma_addr        : out    vl_logic_vector(23 downto 0);
        dma_len         : out    vl_logic_vector(15 downto 0);
        dma_gnt         : in     vl_logic;
        dma_we          : in     vl_logic;
        dma_data        : in     vl_logic_vector(7 downto 0);
        wr_en           : out    vl_logic;
        wr_bank         : out    vl_logic;
        wr_step         : out    vl_logic_vector(1 downto 0);
        wr_lane         : out    vl_logic_vector(3 downto 0);
        wr_data         : out    vl_logic_vector(7 downto 0);
        fill_done       : out    vl_logic
    );
end gemm_dma;
