# run_tb.do - T1..T7: testbench khoi GEMM
#   vsim -c -do "do run_tb.do <HR_LAT> <HR_GAP> <SEED> <ten_wlf>"
#   vd: do run_tb.do 0 0 1 gemm_lat0.wlf     (HyperRAM nhanh nhat)
#       do run_tb.do 8 30 7 gemm_lat8.wlf    (T7: latency 0..8 clk, 30% chu ky trong)
set HR_LAT 0
set HR_GAP 0
set SEED   1
set WLF    gemm.wlf
if {$argc >= 1} { set HR_LAT $1 }
if {$argc >= 2} { set HR_GAP $2 }
if {$argc >= 3} { set SEED   $3 }
if {$argc >= 4} { set WLF    $4 }

do compile.do
vsim -novopt -wlf $WLF work.tb_gemm +HR_LAT=$HR_LAT +HR_GAP=$HR_GAP +SEED=$SEED
# Chi log tin hieu cap gemm_core + trang thai controller/DMA (log toan bo se rat lon)
log /tb_gemm/*
log /tb_gemm/u_dut/*
log /tb_gemm/u_dut/u_ctrl/st /tb_gemm/u_dut/u_ctrl/r /tb_gemm/u_dut/u_ctrl/n0
log /tb_gemm/u_dut/u_ctrl/iss_k /tb_gemm/u_dut/u_ctrl/iss_bank /tb_gemm/u_dut/u_ctrl/tick_cnt
log /tb_gemm/u_dut/u_dma/st /tb_gemm/u_dut/u_dma/fill_bank /tb_gemm/u_dut/u_dma/k0
log /tb_gemm/u_dut/u_arb/st
run -all
quit -f
