# Tong hop thu khoi GEMM bang Gowin (chi kiem tra code tong hop duoc + uoc luong tai nguyen)
# Chay: gw_sh syn.tcl  (trong thu muc my_gemm/syn)
set_device -name GW1NSR-4C GW1NSR-LV4CQN48PC6/I5
set_option -output_base_name gemm_core
set_option -top_module gemm_core
set_option -verilog_std v2001
set_option -include_path {../rtl}
add_file ../rtl/gemm_defs.vh
add_file ../rtl/gemm_array.v
add_file ../rtl/bias_buf.v
add_file ../rtl/bcast_buf.v
add_file ../rtl/elem_pingpong.v
add_file ../rtl/out_buffer.v
add_file ../rtl/gemm_arb.v
add_file ../rtl/gemm_ldmux.v
add_file ../rtl/gemm_dma.v
add_file ../rtl/gemm_ctrl.v
add_file ../rtl/gemm_core.v
run syn
