// Rang buoc clock: 50 MHz (chu ky 20 ns). Bao cao se cho biet Fmax that.
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]
