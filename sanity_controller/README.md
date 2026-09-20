# Sanity Controller

## Overview
The **Sanity Controller** is a System on Chip (SoC) project designed to perform sanity checks and basic hardware validations on the GOWIN FPGA board. It leverages the Gowin EMPU (an ARM Cortex-M3 hard core) to drive simple peripherals like UART and GPIO.

A key highlight of this project is demonstrating how to control the onboard LED through the Cortex-M3 core by mapping it to a specific GPIO pin in the Verilog top module.

## Verilog Code Operation (`top_mcu.v`)
The top-level Verilog module (`soc_top`) acts as the hardware bridge between the external FPGA pins and the internal IP cores. It performs the following primary operations:

1. **Clock Generation (PLL)**: 
   - It instantiates a `Gowin_PLLVR` module.
   - The PLL takes the external crystal clock (`xtal_clk`) as its input and generates a modified (usually doubled or scaled) clock signal called `clk_doubler_out`.
   
2. **Cortex-M3 MCU Instantiation**:
   - It instantiates the `Gowin_EMPU_Top` module, which represents the ARM Cortex-M3 core.
   - The MCU is driven by the `clk_doubler_out` clock from the PLL.
   - The system reset (`reset_n`) is directly routed to the MCU.

3. **LED Blinking / GPIO Mapping**:
   - The `gpio` port of the MCU is 16 bits wide, but only the lower 8 bits (`gpio[7:0]`) are routed to the external inout pins. The upper 8 bits are left floating (high-Z).
   - **Crucially**, the onboard LED is physically connected (via the `.cst` constraint file) to **GPIO7**. 
   - By running firmware on the Cortex-M3 that toggles GPIO pin 7, the SoC successfully blinks the onboard LED, verifying that the clock, MCU core, and GPIO buses are functioning correctly.

4. **UART Communication**:
   - The UART transmission pin (`uart0_txd`) from the MCU is mapped to the external `UART_TX` pin to allow the MCU to print debug messages. 
   - The receive pin (`uart0_rxd`) is tied high (`1'b1`) since only transmission is needed for this sanity check.

## I/O Signals summary
| Signal | Direction | Description |
|--------|-----------|-------------|
| `xtal_clk` | Input | External crystal oscillator clock |
| `reset_n` | Input | Active-low system reset |
| `gpio[7:0]` | Inout | 8-bit GPIO bus. **`gpio[7]` controls the onboard LED**. |
| `UART_TX` | Output | UART transmit data line |

## Project Structure
- `sanity/src/top_mcu.v`: The top-level Verilog file describing the hardware connections.
- `sanity/src/gowin_empu/`: The instantiated Cortex-M3 (Gowin EMPU) IP core.
- `sanity/src/gowin_pllvr/`: The instantiated Phase-Locked Loop (PLL) IP core.
- `sanity/src/sanity_controller.cst`: The physical constraint file mapping the Verilog ports to the actual GOWIN FPGA pins.
