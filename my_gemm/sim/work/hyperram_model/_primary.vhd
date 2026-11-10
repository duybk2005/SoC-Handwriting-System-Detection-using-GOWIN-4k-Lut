library verilog;
use verilog.vl_types.all;
entity hyperram_model is
    generic(
        MEM_BYTES       : integer := 131072;
        MODEL_FILE      : string  := "model_image.mem";
        MODEL_LAST      : integer := 62527
    );
    port(
        clk             : in     vl_logic;
        rst_n           : in     vl_logic;
        hr_req          : in     vl_logic;
        hr_addr         : in     vl_logic_vector(23 downto 0);
        hr_len          : in     vl_logic_vector(15 downto 0);
        hr_ack          : out    vl_logic;
        hr_rdata        : out    vl_logic_vector(7 downto 0);
        hr_rvalid       : out    vl_logic
    );
    attribute mti_svvh_generic_type : integer;
    attribute mti_svvh_generic_type of MEM_BYTES : constant is 1;
    attribute mti_svvh_generic_type of MODEL_FILE : constant is 1;
    attribute mti_svvh_generic_type of MODEL_LAST : constant is 1;
end hyperram_model;
