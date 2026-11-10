library verilog;
use verilog.vl_types.all;
entity gemm_array is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        conv_mode       : in     vl_logic;
        k_len           : in     vl_logic_vector(15 downto 0);
        clear           : in     vl_logic;
        en              : in     vl_logic;
        broadcast       : in     vl_logic_vector(7 downto 0);
        element         : in     vl_logic_vector(127 downto 0);
        bias            : in     vl_logic_vector(511 downto 0);
        tick            : out    vl_logic;
        busy            : out    vl_logic;
        result          : out    vl_logic_vector(511 downto 0)
    );
end gemm_array;
