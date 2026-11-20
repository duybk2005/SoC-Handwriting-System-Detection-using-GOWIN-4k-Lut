# Chay tong hop + place & route bang Gowin (khong can mo IDE)
#   cd lenet_blocks_rtl\syn
#   C:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe run_syn.tcl syn_wrap_gemm
#   C:\Gowin\Gowin_V1.9.11.03_Education_x64\IDE\bin\gw_sh.exe run_syn.tcl syn_wrap_block3
# Ket qua nam trong syn\<top>\impl\pnr\:
#   <top>.rpt.txt  -> tai nguyen (LUT, FF, DSP, BSRAM)
#   <top>.tr.html  -> timing (Fmax)

set top  [lindex $argv 0]
set here [file dirname [file normalize [info script]]]
set rtl  [file normalize "$here/../rtl"]

file mkdir "$here/$top"
cd "$here/$top"

set_device GW1NSR-LV4CQN48PC6/I5 -name GW1NSR-4C

add_file "$rtl/mac.v"
add_file "$rtl/relu_rq.v"
add_file "$rtl/gemm_engine.v"
add_file "$rtl/block3_top.v"
add_file "$here/syn_wrap.v"
add_file "$here/syn.sdc"

set_option -top_module        $top
set_option -output_base_name  $top
set_option -verilog_std       v2001
set_option -use_sspi_as_gpio  1
set_option -use_mspi_as_gpio  1

run all
