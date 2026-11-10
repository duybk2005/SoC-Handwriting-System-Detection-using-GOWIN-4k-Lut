library verilog;
use verilog.vl_types.all;
entity gemm_core is
    generic(
        C1_W            : vl_logic_vector(23 downto 0) := (Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0);
        C1_B            : vl_logic_vector(23 downto 0) := (Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi1, Hi0, Hi0, Hi1, Hi1, Hi0, Hi0, Hi0);
        C3_W            : vl_logic_vector(23 downto 0) := (Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi1, Hi0, Hi1, Hi1, Hi0, Hi0, Hi0, Hi0);
        C3_B            : vl_logic_vector(23 downto 0) := (Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi1, Hi0, Hi1, Hi0, Hi0, Hi0, Hi0, Hi1, Hi0, Hi0, Hi0, Hi0);
        C5_W            : vl_logic_vector(23 downto 0) := (Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi1, Hi0, Hi1, Hi0, Hi0, Hi1, Hi0, Hi1, Hi0, Hi0, Hi0, Hi0);
        C5_B            : vl_logic_vector(23 downto 0) := (Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi1, Hi1, Hi0, Hi0, Hi0, Hi1, Hi0, Hi1, Hi1, Hi1, Hi0, Hi1, Hi0, Hi0, Hi0, Hi0);
        F6_W            : vl_logic_vector(23 downto 0) := (Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi1, Hi1, Hi0, Hi0, Hi0, Hi1, Hi1, Hi1, Hi1, Hi0, Hi1, Hi1, Hi0, Hi0, Hi0, Hi0);
        F6_B            : vl_logic_vector(23 downto 0) := (Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi1, Hi1, Hi1, Hi0, Hi1, Hi1, Hi1, Hi1, Hi0, Hi0, Hi0, Hi1, Hi0, Hi0, Hi0, Hi0);
        OUT_W           : vl_logic_vector(23 downto 0) := (Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi1, Hi1, Hi1, Hi1, Hi0, Hi0, Hi0, Hi0, Hi0, Hi1, Hi1, Hi0, Hi0, Hi0, Hi0, Hi0);
        OUT_B           : vl_logic_vector(23 downto 0) := (Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi1, Hi1, Hi1, Hi1, Hi0, Hi0, Hi1, Hi1, Hi1, Hi0, Hi1, Hi0, Hi1, Hi0, Hi0, Hi0);
        ACT_BASE        : vl_logic_vector(23 downto 0) := (Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi1, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0, Hi0)
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        phase           : in     vl_logic_vector(2 downto 0);
        start           : in     vl_logic;
        done            : out    vl_logic;
        hr_req          : out    vl_logic;
        hr_addr         : out    vl_logic_vector(23 downto 0);
        hr_len          : out    vl_logic_vector(15 downto 0);
        hr_ack          : in     vl_logic;
        hr_rdata        : in     vl_logic_vector(7 downto 0);
        hr_rvalid       : in     vl_logic;
        ob_raddr        : in     vl_logic_vector(11 downto 0);
        ob_rdata        : out    vl_logic_vector(31 downto 0);
        ob_part_full    : out    vl_logic;
        ob_part_id      : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of C1_W : constant is 2;
    attribute mti_svvh_generic_type of C1_B : constant is 2;
    attribute mti_svvh_generic_type of C3_W : constant is 2;
    attribute mti_svvh_generic_type of C3_B : constant is 2;
    attribute mti_svvh_generic_type of C5_W : constant is 2;
    attribute mti_svvh_generic_type of C5_B : constant is 2;
    attribute mti_svvh_generic_type of F6_W : constant is 2;
    attribute mti_svvh_generic_type of F6_B : constant is 2;
    attribute mti_svvh_generic_type of OUT_W : constant is 2;
    attribute mti_svvh_generic_type of OUT_B : constant is 2;
    attribute mti_svvh_generic_type of ACT_BASE : constant is 2;
end gemm_core;
