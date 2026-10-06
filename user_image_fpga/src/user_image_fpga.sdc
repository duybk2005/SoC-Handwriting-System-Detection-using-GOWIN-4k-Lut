create_clock -name clk_osc -period 37.037 -waveform {0 18.518} [get_ports {clk_27m}]
create_clock -name cam_pclk -period 20.000 -waveform {0 10.000} [get_ports {cam_pclk}]
