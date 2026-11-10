library verilog;
use verilog.vl_types.all;
entity bcast_buf is
    port(
        clk             : in     vl_logic;
        we              : in     vl_logic;
        waddr           : in     vl_logic_vector(8 downto 0);
        wdata           : in     vl_logic_vector(7 downto 0);
        raddr           : in     vl_logic_vector(8 downto 0);
        rdata           : out    vl_logic_vector(7 downto 0)
    );
end bcast_buf;
