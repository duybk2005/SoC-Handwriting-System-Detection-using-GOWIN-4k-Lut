library verilog;
use verilog.vl_types.all;
entity out_buffer is
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        pp_mode         : in     vl_logic;
        q_words         : in     vl_logic_vector(11 downto 0);
        save            : in     vl_logic;
        address         : in     vl_logic_vector(11 downto 0);
        wdata           : in     vl_logic_vector(31 downto 0);
        part_full       : out    vl_logic;
        part_id         : out    vl_logic;
        raddr           : in     vl_logic_vector(11 downto 0);
        rdata           : out    vl_logic_vector(31 downto 0)
    );
end out_buffer;
