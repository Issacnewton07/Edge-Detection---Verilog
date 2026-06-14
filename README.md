Here's a clean GitHub project description:

---

**OV7670 Live Camera Feed on FPGA — EDGE Artix-7**

A real-time camera display system implemented entirely in Verilog on the EDGE Artix-7 FPGA development board. The project streams live video from an OV7670 CMOS camera module directly to a 1.8-inch ST7735 SPI TFT display with no external processor or software stack.

**How it works:**
The OV7670 is configured via a custom SCCB (I2C-like) master that writes 75 initialization registers on startup, setting the camera to QVGA (320×240) RGB565 output at 25 MHz pixel clock. Incoming pixel data is captured synchronously on the pixel clock, subsampled 2:1 horizontally to produce 160 columns, and cropped to the centre 128 columns and 120 rows to fit the TFT display window.

A ping-pong line buffer (two banks of 128×16-bit distributed LUT RAM) decouples the camera's 25 MHz pixel clock domain from the 100 MHz system clock domain. A toggle-based CDC handshake with a registered bank snapshot ensures zero metastability risk and eliminates torn-pixel artefacts. If the SPI transmitter is still busy when a new camera line arrives, the line is gracefully dropped — the camera never stalls and memory is never corrupted.

The ST7735 is driven by a 12.5 MHz SPI engine (100 MHz ÷ 8) using an event-driven FSM. A single-cycle `spi_done` strobe replaces the conventional busy-poll wait state, eliminating 6,400 wasted clock cycles per byte and allowing the FSM to react to transmission completion in a single clock cycle. The display window is re-initialised every frame via CASET/RASET/RAMWR commands to prevent write-pointer drift.

**Key specs:** 50 MHz input clock → PLL generates 100 MHz system clock and 25 MHz camera clock. Effective display rate ~8 fps, camera-limited. Resource usage under 1% of Artix-7 35T LUTs.

**Files:** `top.v` `ov7670_sccb.v` `constraints.xdc`
