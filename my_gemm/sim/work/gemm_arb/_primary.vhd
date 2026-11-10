library verilog;
use verilog.vl_types.all;
entity gemm_arb is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        req             : in     vl_logic_vector(2 downto 0);
        addr0           : in     vl_logic_vector(23 downto 0);
        addr1           : in     vl_logic_vector(23 downto 0);
        addr2           : in     vl_logic_vector(23 downto 0);
        len0            : in     vl_logic_vector(15 downto 0);
        len1            : in     vl_logic_vector(15 downto 0);
        len2            : in     vl_logic_vector(15 downto 0);
        gnt             : out    vl_logic_vector(2 downto 0);
        load_select     : out    vl_logic_vector(1 downto 0);
        data_phase      : out    vl_logic;
        hr_req          : out    vl_logic;
        hr_addr         : out    vl_logic_vector(23 downto 0);
        hr_len          : out    vl_logic_vector(15 downto 0);
        hr_ack          : in     vl_logic;
        hr_rvalid       : in     vl_logic
    );
end gemm_arb;
