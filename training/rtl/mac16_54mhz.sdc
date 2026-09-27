# Target slightly tighter than 1e9/54e6 = 18.518518 ns.
create_clock -name mac_clk -period 18.518 -waveform {0 9.259} [get_ports {clk}]
# Harness-only interface budget; replace with real integration constraints.
set_input_delay -max 2.000 -clock mac_clk [get_ports {rst scan_en scan_in start layer_fc2 in_valid capture_result result_shift}]
set_input_delay -min 0.000 -clock mac_clk [get_ports {rst scan_en scan_in start layer_fc2 in_valid capture_result result_shift}]
set_output_delay -max 2.000 -clock mac_clk [get_ports {scan_out in_ready busy done}]
set_output_delay -min 0.000 -clock mac_clk [get_ports {scan_out in_ready busy done}]
