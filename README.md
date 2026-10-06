# Real-Time Handwritten Digit Recognition SoC (`user_image`)

This project implements a real-time handwritten digit recognition System-on-Chip (SoC) deployed on the **Sipeed Tang Nano 4K** development board (featuring the **Gowin GW1NSR-LV4C** FPGA with an integrated **ARM Cortex-M3** hard core).

The system captures video from an **OV2640** camera sensor, downsamples and normalizes input frames in a hybrid HW/SW pipeline, accelerates a Multi-Layer Perceptron (MLP) neural network (784-16-10) using a custom hardware MAC accelerator and MCU post-processing, and outputs the live classification results and video stream over **HDMI (640x480 @ 60Hz)**.

---

## 1. System Architecture & Pipeline

The system is designed with a tightly coupled Hardware/Software (HW/SW) co-design architecture communicating over an internal AMBA **AHB-Lite** bus:

```
[OV2640 Camera (DVP)] 
        │
        ▼ (PIXCLK domain: crop 448x448 -> downsample 112x112 gray)
[FPGA: cam_capture & Band Buffer (SRAM)]
        │
        ▼ (AHB-Lite Bus Master: MCU reads 4-row bands)
[ARM Cortex-M3 (Firmware)]
   - Image scaling & MNIST-like normalization (28x28, center-of-mass)
   - Writes normalized image to PARAM/IMAGE RAM
        │
        ▼ (Triggers MAC accelerator via CTRL register)
[FPGA: mac_fc (Hardware MAC Engine)]
   - Computes FC1: Acc1[16] = W1 * Image + B1
        │
        ▼ (MCU reads Acc1, computes ReLU & Requantization)
[ARM Cortex-M3 (Firmware)]
   - Hidden[16] = Requant(ReLU(Acc1))
   - Writes Hidden[16] back to PARAM RAM
        │
        ▼ (Triggers MAC accelerator for FC2)
[FPGA: mac_fc (Hardware MAC Engine)]
   - Computes FC2: Logits[10] = W2 * Hidden + B2
        │
        ▼ (MCU reads Logits)
[ARM Cortex-M3 (Firmware)]
   - Argmax classification, confidence margin check, temporal smoothing
   - Writes predicted digit to DIGIT register
        │
        ▼
[FPGA: svo_hdmi & digit_7seg]
   - Centers 8x scaled 28x28 image (224x224) on 640x480 display
   - Renders 7-segment predicted digit overlay and debug diagnostic tiles
```

---

## 2. Main Source Code Structure

> *Note: Backup folders and temporary revision snapshots have been excluded from this breakdown.*

### 2.1. FPGA RTL Design (`user_image_fpga/src/`)

- [`top.v`](<file:///c:/Users/diego/OneDrive/Documents/STUDY_MATERIAL/ChuuyenDe/project%201/user_image/user_image_fpga/src/top.v>): **Top-Level Module**. Interconnects clock domains (27 MHz oscillator, PLL, clock divider), the OV2640 SCCB controller, camera capture engine, AHB bus interface, hardware MAC engine, Cortex-M3 hard core, and HDMI video serialization.
- [`ahb_band_buf.v`](<file:///c:/Users/diego/OneDrive/Documents/STUDY_MATERIAL/ChuuyenDe/project%201/user_image/user_image_fpga/src/ahb_band_buf.v>): **AHB-Lite Slave & Memory Controller**. Bridges the Cortex-M3 MCU to Block SRAMs (BSRAM) and peripheral registers. Manages dual-port access for image buffers, network parameters, intermediate layers, and control/status registers.
- [`mac_fc.v`](<file:///c:/Users/diego/OneDrive/Documents/STUDY_MATERIAL/ChuuyenDe/project%201/user_image/user_image_fpga/src/mac_fc.v>): **Hardware MAC Accelerator**. Performs sequential Multiply-Accumulate operations for Fully Connected layers (FC1: 784 inputs $\rightarrow$ 16 outputs, FC2: 16 inputs $\rightarrow$ 10 outputs) directly accessing PARAM RAM.
- [`cam_capture.v`](<file:///c:/Users/diego/OneDrive/Documents/STUDY_MATERIAL/ChuuyenDe/project%201/user_image/user_image_fpga/src/cam_capture.v>): **Camera Capture Engine**. Operates in the camera `PIXCLK` domain. Crops a central 448x448 square from the 640x480 RAW10 Bayer stream, averages neighboring pixels to extract 112x112 grayscale data, packs 4 pixels per 32-bit word, and buffers them into 4-line bands with MCU handshaking.
- [`svo_hdmi.v`](<file:///c:/Users/diego/OneDrive/Documents/STUDY_MATERIAL/ChuuyenDe/project%201/user_image/user_image_fpga/src/svo_hdmi.v>): **HDMI Video Controller**. Generates 640x480 @ 60Hz timing, scales the 28x28 normalized grayscale image by 8x (to 224x224) at the screen center, and overlays status tiles.
- [`digit_7seg.v`](<file:///c:/Users/diego/OneDrive/Documents/STUDY_MATERIAL/ChuuyenDe/project%201/user_image/user_image_fpga/src/digit_7seg.v>): **7-Segment Display Generator**. Renders the recognized digit (0–9), error code (`E` for low confidence), or empty frame symbol (`-`) as an on-screen 7-segment digital display.
- [`ov2640/`](<file:///c:/Users/diego/OneDrive/Documents/STUDY_MATERIAL/ChuuyenDe/project%201/user_image/user_image_fpga/src/ov2640>): SCCB/I2C master interface (`I2C_Interface.v`), register sequence definition (`OV2640_Registers.v`), and power-on state machine (`OV2640_Controller.v`) for initializing the sensor.
- [`hdmi/`](<file:///c:/Users/diego/OneDrive/Documents/STUDY_MATERIAL/ChuuyenDe/project%201/user_image/user_image_fpga/src/hdmi>): DVI/TMDS encoder (`svo_enc.v`) and parallel-to-serial TMDS output serializer (`svo_tmds.v`).
- [`gowin_pllvr/`](<file:///c:/Users/diego/OneDrive/Documents/STUDY_MATERIAL/ChuuyenDe/project%201/user_image/user_image_fpga/src/gowin_pllvr>) & [`gowin_clkdiv/`](<file:///c:/Users/diego/OneDrive/Documents/STUDY_MATERIAL/ChuuyenDe/project%201/user_image/user_image_fpga/src/gowin_clkdiv>): Gowin IP primitives generating 126 MHz (`clk_5x`), 63 MHz (`clk_sys`), 25.2 MHz (`clk_pixel`), and 12.6 MHz (camera `cam_xclk`) from the 27 MHz onboard crystal.
- [`gowin_empu/`](<file:///c:/Users/diego/OneDrive/Documents/STUDY_MATERIAL/ChuuyenDe/project%201/user_image/user_image_fpga/src/gowin_empu>): Instantiation wrapper for the GW1NSR-4C Cortex-M3 hard core.
- [`user_image_fpga.cst`](<file:///c:/Users/diego/OneDrive/Documents/STUDY_MATERIAL/ChuuyenDe/project%201/user_image/user_image_fpga/src/user_image_fpga.cst>): Physical pin constraint mapping for Tang Nano 4K (Camera DVP pins, HDMI LVDS differential pairs, clock, LED).
- [`user_image_fpga.sdc`](<file:///c:/Users/diego/OneDrive/Documents/STUDY_MATERIAL/ChuuyenDe/project%201/user_image/user_image_fpga/src/user_image_fpga.sdc>): Timing constraints specifying clock frequencies.

---

### 2.2. Cortex-M3 Firmware (`template/`)

- [`main.c`](<file:///c:/Users/diego/OneDrive/Documents/STUDY_MATERIAL/ChuuyenDe/project%201/user_image/template/main.c>): **Firmware Application Logic**:
  - **Boot Phase 0**: Copies model parameters (quantized weights $W_1$, $W_2$ and biases $B_1$, $B_2$) from MCU Flash into FPGA PARAM RAM.
  - **Optional Self-Test**: Validates inference pipeline against precomputed test vectors.
  - **Main Frame Loop**:
    1. Reads camera bands via AHB, downsamples 112x112 to 28x28.
    2. Performs MNIST normalization: automatic background/ink contrast detection (handles dark on light paper or light on dark screen), tight bounding box extraction, isotropic scaling to a 20 px bounding box, and center-of-mass alignment to $(13.5, 13.5)$.
    3. Launches hardware MAC for FC1, performs software ReLU and 8-bit requantization, launches hardware MAC for FC2.
    4. Computes argmax, verifies confidence margin ($Logit_{max} - Logit_{2nd} \ge 1500$), filters blank frames, applies temporal debouncing across consecutive frames (`STABLE_N`), and writes the final digit to the FPGA display register.
- [`params.h`](<file:///c:/Users/diego/OneDrive/Documents/STUDY_MATERIAL/ChuuyenDe/project%201/user_image/template/params.h>): Quantized weight arrays and bias coefficients embedded into the firmware image.
- [`test_mlp.h`](<file:///c:/Users/diego/OneDrive/Documents/STUDY_MATERIAL/ChuuyenDe/project%201/user_image/template/test_mlp.h>): Reference MNIST test samples and ground truth outputs for sanity testing.
- [`gw1ns4c_conf.h`](<file:///c:/Users/diego/OneDrive/Documents/STUDY_MATERIAL/ChuuyenDe/project%201/user_image/template/gw1ns4c_conf.h>), [`gw1ns4c_it.c`](<file:///c:/Users/diego/OneDrive/Documents/STUDY_MATERIAL/ChuuyenDe/project%201/user_image/template/gw1ns4c_it.c>), [`gw1ns4c_it.h`](<file:///c:/Users/diego/OneDrive/Documents/STUDY_MATERIAL/ChuuyenDe/project%201/user_image/template/gw1ns4c_it.h>): System initialization, peripheral setup, and interrupt vector tables.
- [`lib/`](<file:///c:/Users/diego/OneDrive/Documents/STUDY_MATERIAL/ChuuyenDe/project%201/user_image/lib>): CMSIS hardware abstraction layer, standard peripheral drivers, and linker script ([`gw1ns4c_flash.ld`](<file:///c:/Users/diego/OneDrive/Documents/STUDY_MATERIAL/ChuuyenDe/project%201/user_image/lib/Script/flash/gmd/gw1ns4c_flash.ld>)).

---

## 3. AHB Memory Map (Base: `0xA0000000`)

The Cortex-M3 controls and interacts with the FPGA fabric via standard 32-bit memory-mapped I/O:

| Offset Range        | Access | Name                   | Description                                                                                |
| :------------------ | :----- | :--------------------- | :----------------------------------------------------------------------------------------- |
| `0x0000 - 0x030F` | R/W    | `IMAGE` (784 B)      | Display image buffer rendered by HDMI.                                                     |
| `0x0310 - 0x034F` | R      | `ACC1` (16 x INT32)  | FC1 output accumulated by hardware MAC.                                                    |
| `0x0350 - 0x035F` | R/W    | `HIDDEN` (16 x INT8) | Requantized activations written by MCU, read by MAC for FC2.                               |
| `0x0360 - 0x0387` | R      | `LOGIT` (10 x INT32) | FC2 output logits calculated by hardware MAC.                                              |
| `0x0388`          | R/W    | `DIGIT`              | Output register:`0..9` (Digit), `14` ('E' uncertain), `15` ('-' blank).              |
| `0x0400 - 0x070F` | R/W    | `NET` (784 B)        | MAC input copy for normalized MNIST image.                                                 |
| `0x0800 - 0x3FFF` | R/W    | `PARAM`              | Weight & bias storage ($W_1$, $W_2$, $B_1$, $B_2$).                                |
| `0x4000 - 0x41BF` | R      | `BAND` (112 Words)   | 4-row camera band buffer filled by`cam_capture`.                                         |
| `0x4800`          | W      | `CTRL`               | bit 0: Next band, bit 1: New frame, bit 2: MAC start, bit 3: MAC layer (0: FC1, 1: FC2).   |
| `0x4804`          | R      | `STATUS`             | bit 0: Cam busy, bit 1: Band ready, bit 2: Cam CFG done, bit 3: MAC busy, bit 4: MAC done. |
| `0x4808`          | R/W    | `LED`                | Controls onboard debug LED.                                                                |
| `0x480C`          | R      | `DBG`                | Diagnostic metrics:`[15:0]` pixels/row, `[31:16]` rows/frame.                          |
| `0x4810`          | R/W    | `TEST`               | 8-bit diagnostic indicator flags shown on the second HDMI HUD row.                         |

---

## 4. Requirements & Tools

### Hardware

- **Sipeed Tang Nano 4K** (Gowin GW1NSR-LV4CQN48PC6/I5).
- **OV2640 Camera Module** plugged into the onboard DVP connector.
- **HDMI Display** and standard HDMI cable.
- **USB Type-C cable** (with data support for JTAG/programming and UART power).

### Software & Toolchain

- **Gowin EDA (FPGA Designer)** (V1.9.8 or newer).
- **Gowin MCU Designer (GMD)** or **GNU Arm Embedded Toolchain** (`arm-none-eabi-gcc`).
- **Gowin Programmer** (bundled with Gowin EDA).

---

## 5. Build Instructions

### Step 1: Synthesize FPGA Bitstream

1. Launch **Gowin EDA**.
2. Open the project file:`user_image_fpga/user_image_fpga.gprj`
3. Ensure all source files in `src/` and constraints (`user_image_fpga.cst`, `user_image_fpga.sdc`) are included and enabled.
4. Under the **Process** pane, double-click **Place & Route** to run synthesis and routing.
5. Upon successful completion, the generated bitstream will be located at:
   `user_image_fpga/impl/pnr/user_image_fpga.fs`

### Step 2: Build Cortex-M3 Firmware

You can build the MCU firmware using either **Gowin MCU Designer (GMD)** or the CLI:

#### Using Command Line / Make:

```bash
cd "Debug"
make all
```

#### Using Gowin MCU Designer (GMD):

1. Open GMD and import the `user_image` project directory.
2. Select **Project $\rightarrow$ Build Project** (or build configuration `Debug`).
3. The build generates:
   - `Debug/user_image_c.elf`
   - `Debug/user_image_c.bin` (Binary image for flash programming)

---

## 6. Flashing & Running (Programming Guide)

The GW1NSR-4C chip contains both FPGA SRAM / Embedded Flash and MCU Embedded Flash.

### Step 1: Connect the Board

1. Plug the OV2640 camera into the Tang Nano 4K DVP slot.
2. Connect the HDMI port of the board to your monitor.
3. Connect the Tang Nano 4K to your computer via USB-C.

---

### Step 2: Program FPGA Bitstream

1. Open **Gowin Programmer**.
2. Click **Scan Device**. You should see `GW1NSR-4C` detected.
3. Under the **Operation** column, configure the programming mode:
   - **Volatile Testing (SRAM Mode)**:
     - Access Mode: `SRAM Mode`
     - Operation: `SRAM Program`
     - File: Browse and select `user_image_fpga/impl/pnr/user_image_fpga.fs`.
   - **Permanent Flashing (Flash Mode)**:
     - Access Mode: `embFlash Mode`
     - Operation: `embFlash Erase, Program`
     - File: Browse and select `user_image_fpga/impl/pnr/user_image_fpga.fs`.
4. Click **Program / Configure** (play icon) and wait until completion (Status: `100% / Save Success`).

---

### Step 3: Flash MCU Firmware Binary

1. In **Gowin Programmer**, click **Edit $\rightarrow$ Configure Device** (or double-click the device operation).
2. Configure MCU programming options:
   - Access Mode: `MCU Mode` (or `embFlash Mode` depending on Programmer version).
   - Operation: `embFlash Erase, Program` (targeting MCU Flash address `0x00000000`).
   - File: Browse and select `Debug/user_image_c.bin`.
3. Click **Program / Configure** to flash the firmware into the Cortex-M3 internal flash.
4. Press the hardware **Reset** button on the Tang Nano 4K board to boot the new firmware.

*(Alternatively, GMD's built-in debugger with OpenOCD/JTAG can be used to directly download and run `user_image_c.elf` during development).*

---

## 7. Operational Verification & Display Diagnostics

Once booted, the HDMI display presents the following layout:

1. **Live Camera / Processed Feed (Center)**: Displays the 28x28 normalized grayscale digit expanded 8x ($224 \times 224$ pixels).
2. **Predicted Output (Right Panel)**: A large 7-segment digital display showing:
   - `0` – `9`: Recognized digit with solid confidence.
   - `E`: Low confidence / uncertain (difference between the top two logits is below the margin threshold).
   - `-`: Blank frame or insufficient ink contrast.
3. **Debug Status Tiles (Top Screen HUD)**:
   - **Row 1 (Hardware Diagnostics)**:
     - Bit 0: HDMI video active.
     - Bit 1: OV2640 SCCB configuration completed.
     - Bit 2: Camera `PCLK` active.
     - Bit 3: Camera `VSYNC` active.
     - Bit 4: Camera line width valid ($640$ pixels).
     - Bit 5: Camera vertical frame lines valid ($460 - 500$ lines).
     - Bit 6: MCU frame processing toggle.
     - Bit 7: Camera band buffer write complete toggle.
   - **Row 2 (Self-Test / Pipeline Verification)**:
     - Tile 0: Phase 0 parameter initialization finished.
     - Tile 1–6: Internal hardware MAC and layer validation flags (when self-test is enabled).
     - Tile 7: Frame active detection (ink presence and sufficient contrast).
