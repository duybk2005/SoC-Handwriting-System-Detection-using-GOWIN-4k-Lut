# compile.do - bien dich RTL + testbench (chay trong thu muc my_gemm/sim)
#   vsim -c -do "do compile.do; quit -f"
if {![file exists work]} { vlib work }
vlog -work work +incdir+../rtl \
    ../rtl/gemm_array.v ../rtl/bias_buf.v ../rtl/bcast_buf.v ../rtl/elem_pingpong.v \
    ../rtl/out_buffer.v ../rtl/gemm_arb.v ../rtl/gemm_ldmux.v ../rtl/gemm_dma.v \
    ../rtl/gemm_ctrl.v ../rtl/gemm_core.v \
    ../tb/hyperram_model.v ../tb/tb_gemm_array.v ../tb/tb_gemm.v
