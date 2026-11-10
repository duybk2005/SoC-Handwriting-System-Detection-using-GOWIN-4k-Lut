# wave.do - mo waveform da luu:  vsim -view <file>.wlf -do wave.do
onerror {resume}
quietly WaveActivateNextPane {} 0
add wave -noupdate -divider {Port ngoai (Figure 1)}
add wave -noupdate /tb_gemm/clk
add wave -noupdate /tb_gemm/rst_n
add wave -noupdate -radix unsigned /tb_gemm/phase
add wave -noupdate /tb_gemm/start
add wave -noupdate /tb_gemm/done
add wave -noupdate -divider {HyperRAM}
add wave -noupdate /tb_gemm/hr_req
add wave -noupdate -radix unsigned /tb_gemm/hr_addr
add wave -noupdate -radix unsigned /tb_gemm/hr_len
add wave -noupdate /tb_gemm/hr_ack
add wave -noupdate /tb_gemm/hr_rvalid
add wave -noupdate -radix hexadecimal /tb_gemm/hr_rdata
add wave -noupdate -radix unsigned /tb_gemm/u_dut/load_select
add wave -noupdate -divider {Controller}
add wave -noupdate -radix unsigned /tb_gemm/u_dut/u_ctrl/st
add wave -noupdate -radix unsigned /tb_gemm/u_dut/u_ctrl/r
add wave -noupdate -radix unsigned /tb_gemm/u_dut/u_ctrl/n0
add wave -noupdate -radix unsigned /tb_gemm/u_dut/u_ctrl/iss_k
add wave -noupdate /tb_gemm/u_dut/clear
add wave -noupdate /tb_gemm/u_dut/mac_en
add wave -noupdate /tb_gemm/u_dut/tick
add wave -noupdate /tb_gemm/u_dut/elem_valid
add wave -noupdate /tb_gemm/u_dut/save
add wave -noupdate -radix unsigned /tb_gemm/u_dut/address
add wave -noupdate -radix unsigned /tb_gemm/u_dut/lane_sel
add wave -noupdate -divider {Datapath}
add wave -noupdate -radix decimal /tb_gemm/u_dut/broadcast
add wave -noupdate -radix hexadecimal /tb_gemm/u_dut/element
add wave -noupdate -radix hexadecimal /tb_gemm/u_dut/bias
add wave -noupdate -radix hexadecimal /tb_gemm/u_dut/result
add wave -noupdate -divider {DMA / Out_buffer}
add wave -noupdate -radix unsigned /tb_gemm/u_dut/u_dma/st
add wave -noupdate /tb_gemm/u_dut/u_dma/fill_bank
add wave -noupdate /tb_gemm/ob_part_full
add wave -noupdate /tb_gemm/ob_part_id
add wave -noupdate -radix unsigned /tb_gemm/ob_raddr
add wave -noupdate -radix decimal /tb_gemm/ob_rdata
TreeUpdate [SetDefaultTree]
configure wave -namecolwidth 260
configure wave -timelineunits us
update
wave zoom full
