library verilog;
use verilog.vl_types.all;
entity elem_pingpong is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        init            : in     vl_logic;
        wr_en           : in     vl_logic;
        wr_bank         : in     vl_logic;
        wr_step         : in     vl_logic_vector(1 downto 0);
        wr_lane         : in     vl_logic_vector(3 downto 0);
        wr_data         : in     vl_logic_vector(7 downto 0);
        fill_done       : in     vl_logic;
        valid           : out    vl_logic_vector(1 downto 0);
        mac_en          : in     vl_logic;
        tick            : in     vl_logic;
        element         : out    vl_logic_vector(127 downto 0)
    );
end elem_pingpong;
