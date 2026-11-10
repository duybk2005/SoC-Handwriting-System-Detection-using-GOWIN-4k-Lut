# run_t0.do - T0: unit test gemm_array
#   vsim -c -do run_t0.do
do compile.do
vsim -novopt -wlf t0_array.wlf work.tb_gemm_array
log -r /*
run -all
quit -f
