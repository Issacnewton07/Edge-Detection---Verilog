## ============================================================
## constraints.xdc  —  OV7670 → ST7735 TFT Live Video
## EDGE Artix-7 board
## ============================================================

## Clock
set_property -dict { PACKAGE_PIN N11 IOSTANDARD LVCMOS33 } [get_ports { clk }];
create_clock -add -name sys_clk_pin -period 20.00 -waveform {0 10} [get_ports { clk }];

## Push Buttons (active-high, PULLDOWN)
set_property -dict { PACKAGE_PIN K13 IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { pb[0] }];
set_property -dict { PACKAGE_PIN L14 IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { pb[1] }];
set_property -dict { PACKAGE_PIN M12 IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { pb[2] }];
set_property -dict { PACKAGE_PIN L13 IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { pb[3] }];
set_property -dict { PACKAGE_PIN M14 IOSTANDARD LVCMOS33 PULLDOWN true } [get_ports { pb[4] }];

## LEDs
set_property -dict { PACKAGE_PIN J3  IOSTANDARD LVCMOS33 } [get_ports { led[0]  }];
set_property -dict { PACKAGE_PIN H3  IOSTANDARD LVCMOS33 } [get_ports { led[1]  }];
set_property -dict { PACKAGE_PIN J1  IOSTANDARD LVCMOS33 } [get_ports { led[2]  }];
set_property -dict { PACKAGE_PIN K1  IOSTANDARD LVCMOS33 } [get_ports { led[3]  }];
set_property -dict { PACKAGE_PIN L3  IOSTANDARD LVCMOS33 } [get_ports { led[4]  }];
set_property -dict { PACKAGE_PIN L2  IOSTANDARD LVCMOS33 } [get_ports { led[5]  }];
set_property -dict { PACKAGE_PIN K3  IOSTANDARD LVCMOS33 } [get_ports { led[6]  }];
set_property -dict { PACKAGE_PIN K2  IOSTANDARD LVCMOS33 } [get_ports { led[7]  }];
set_property -dict { PACKAGE_PIN K5  IOSTANDARD LVCMOS33 } [get_ports { led[8]  }];
set_property -dict { PACKAGE_PIN P6  IOSTANDARD LVCMOS33 } [get_ports { led[9]  }];
set_property -dict { PACKAGE_PIN R7  IOSTANDARD LVCMOS33 } [get_ports { led[10] }];
set_property -dict { PACKAGE_PIN R6  IOSTANDARD LVCMOS33 } [get_ports { led[11] }];
set_property -dict { PACKAGE_PIN T5  IOSTANDARD LVCMOS33 } [get_ports { led[12] }];
set_property -dict { PACKAGE_PIN R5  IOSTANDARD LVCMOS33 } [get_ports { led[13] }];
set_property -dict { PACKAGE_PIN T10 IOSTANDARD LVCMOS33 } [get_ports { led[14] }];
set_property -dict { PACKAGE_PIN T9  IOSTANDARD LVCMOS33 } [get_ports { led[15] }];

## OV7670 CMOS Camera
set_property -dict { PACKAGE_PIN M16 IOSTANDARD LVCMOS33 } [get_ports { ov7670_sioc    }];
set_property -dict { PACKAGE_PIN N16 IOSTANDARD LVCMOS33 } [get_ports { ov7670_siod    }];
set_property -dict { PACKAGE_PIN P15 IOSTANDARD LVCMOS33 } [get_ports { ov7670_vsync   }];
set_property -dict { PACKAGE_PIN P16 IOSTANDARD LVCMOS33 } [get_ports { ov7670_href    }];
set_property -dict { PACKAGE_PIN R15 IOSTANDARD LVCMOS33 } [get_ports { ov7670_pclk    }];
set_property -dict { PACKAGE_PIN R16 IOSTANDARD LVCMOS33 } [get_ports { ov7670_xclk    }];
set_property -dict { PACKAGE_PIN T14 IOSTANDARD LVCMOS33 } [get_ports { ov7670_data[7] }];
set_property -dict { PACKAGE_PIN T15 IOSTANDARD LVCMOS33 } [get_ports { ov7670_data[6] }];
set_property -dict { PACKAGE_PIN N13 IOSTANDARD LVCMOS33 } [get_ports { ov7670_data[5] }];
set_property -dict { PACKAGE_PIN P13 IOSTANDARD LVCMOS33 } [get_ports { ov7670_data[4] }];
set_property -dict { PACKAGE_PIN N14 IOSTANDARD LVCMOS33 } [get_ports { ov7670_data[3] }];
set_property -dict { PACKAGE_PIN P14 IOSTANDARD LVCMOS33 } [get_ports { ov7670_data[2] }];
set_property -dict { PACKAGE_PIN P10 IOSTANDARD LVCMOS33 } [get_ports { ov7670_data[1] }];
set_property -dict { PACKAGE_PIN P11 IOSTANDARD LVCMOS33 } [get_ports { ov7670_data[0] }];
set_property -dict { PACKAGE_PIN R12 IOSTANDARD LVCMOS33 } [get_ports { ov7670_reset   }];
set_property -dict { PACKAGE_PIN T12 IOSTANDARD LVCMOS33 } [get_ports { ov7670_pwdn    }];

## ST7735 TFT SPI Display
set_property -dict { PACKAGE_PIN T13 IOSTANDARD LVCMOS33 } [get_ports { tft_sck   }];
set_property -dict { PACKAGE_PIN R10 IOSTANDARD LVCMOS33 } [get_ports { tft_sdi   }];
set_property -dict { PACKAGE_PIN R11 IOSTANDARD LVCMOS33 } [get_ports { tft_dc    }];
set_property -dict { PACKAGE_PIN N9  IOSTANDARD LVCMOS33 } [get_ports { tft_reset }];
set_property -dict { PACKAGE_PIN P9  IOSTANDARD LVCMOS33 } [get_ports { tft_cs    }];

## ============================================================
## Timing constraints
## ============================================================

## OV7670 PCLK is an input clock — tell Vivado its frequency
create_clock -add -name pclk_pin -period 40.00 [get_ports { ov7670_pclk }];

## The two clock domains (clk_cam from PLL, ov7670_pclk from camera)
## are asynchronous. Declare them as such so Vivado doesn't try to
## time the CDC crossing paths (we handle it manually with double-sync).
set_clock_groups -asynchronous \
    -group [get_clocks -include_generated_clocks sys_clk_pin] \
    -group [get_clocks pclk_pin];

## Relax false paths on TFT outputs (slow SPI, no setup concern)
set_false_path -to [get_ports { tft_sck tft_sdi tft_dc tft_reset tft_cs }];

## Relax false paths on LED outputs
set_false_path -to [get_ports { led[*] }];

## OV7670 xclk output — driven by ODDR, no timing constraint needed
set_false_path -to [get_ports { ov7670_xclk }];

## OV7670 control outputs
set_false_path -to [get_ports { ov7670_reset ov7670_pwdn }];
set_false_path -to [get_ports { ov7670_sioc ov7670_siod }];
