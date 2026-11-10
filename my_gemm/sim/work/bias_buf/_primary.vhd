library verilog;
use verilog.vl_types.all;
entity bias_buf is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        conv_mode       : in     vl_logic;
        ld_start        : in     vl_logic;
        ld_we           : in     vl_logic;
        ld_data         : in     vl_logic_vector(7 downto 0);
        bias            : out    vl_logic_vector(511 downto 0)
    );
end bias_buf;
