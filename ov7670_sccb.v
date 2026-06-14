// ============================================================
// ov7670_sccb.v  —  SCCB master for OV7670 register init
// Fixes applied:
//   [F1] TSLB 3A04 → 3A00 : bit2 was swapping pixel byte order
//        causing red and blue channels to be visually swapped
//   [F2] DBLV 6B4A → 6B0A : disables internal PLL, PCLK = xclk
//        = 25 MHz; previous value multiplied clock ×4 and could
//        push PCLK to 50 MHz, outrunning the capture logic
// ============================================================
module ov7670_sccb #(
    parameter CLK_FREQ  = 25_000_000,   // clk_cam = 25 MHz
    parameter SCCB_FREQ = 100_000       // 100 kHz SCCB bus
)(
    input  wire clk,
    input  wire rst,
    output reg  sioc,
    inout  wire siod,
    output reg  done
);

// ---- clock divider: generates quarter-period ticks ----
localparam DIVIDER = CLK_FREQ / (4 * SCCB_FREQ);   // = 62 @ 25 MHz
reg [$clog2(DIVIDER+1)-1:0] div_cnt;
reg [1:0] phase;   // 0-3: four quarter-periods per SCL cycle

always @(posedge clk or posedge rst) begin
    if (rst) begin div_cnt <= 0; phase <= 0; end
    else if (div_cnt == DIVIDER-1) begin div_cnt <= 0; phase <= phase+1; end
    else div_cnt <= div_cnt + 1;
end
wire sccb_tick = (div_cnt == DIVIDER-1);

// ---- register init ROM  {reg_addr[7:0], value[7:0]} ----
reg [15:0] rom [0:74];
initial begin
    rom[0]  = 16'h1280; // COM7:  software reset — must be first
    rom[1]  = 16'h1204; // COM7:  RGB output, QVGA
    rom[2]  = 16'h1100; // CLKRC: no prescale, use xclk directly
    rom[3]  = 16'h0C00; // COM3:  defaults
    rom[4]  = 16'h3E00; // COM14: no PCLK scaling
    rom[5]  = 16'h8C02; // RGB444: select RGB565 (not RGB444)
    rom[6]  = 16'h4010; // COM15: RGB565, full output range 0x00-0xFF
    // [F1] was 3A04 — bit[2] (YUYV/SWAP) reversed byte order inside
    //      each RGB565 word, making every pixel appear red-blue swapped
    rom[7]  = 16'h3A00; // TSLB:  normal YUYV order, no line reversal
    rom[8]  = 16'h1714; // HSTART
    rom[9]  = 16'h1802; // HSTOP
    rom[10] = 16'h3200; // HREF
    rom[11] = 16'h1903; // VSTART
    rom[12] = 16'h1A7B; // VSTOP
    rom[13] = 16'h030A; // VREF
    rom[14] = 16'h703A; // SCALING_XSC
    rom[15] = 16'h7135; // SCALING_YSC
    rom[16] = 16'h7211; // SCALING_DCWCTR  (QVGA: ÷2 in both axes)
    rom[17] = 16'h73F1; // SCALING_PCLK_DIV
    rom[18] = 16'hA202; // SCALING_PCLK_DELAY
    rom[19] = 16'h13E0; // COM8:  disable AWB/AEC during matrix load
    rom[20] = 16'h00C0; // GAIN
    rom[21] = 16'h1060; // AECH
    rom[22] = 16'h0D40; // COM4
    rom[23] = 16'h1418; // COM9:  AGC 4× ceiling
    rom[24] = 16'h4FB3; // MTX1
    rom[25] = 16'h50B3; // MTX2
    rom[26] = 16'h5100; // MTX3
    rom[27] = 16'h523D; // MTX4
    rom[28] = 16'h53A7; // MTX5
    rom[29] = 16'h54E4; // MTX6
    rom[30] = 16'h589E; // MTXS
    rom[31] = 16'h3DC8; // COM13: gamma enable, UV auto-adjust
    rom[32] = 16'h7A20; // SLOP  (gamma curve)
    rom[33] = 16'h7B10;
    rom[34] = 16'h7C1E;
    rom[35] = 16'h7D35;
    rom[36] = 16'h7E5A;
    rom[37] = 16'h7F69;
    rom[38] = 16'h8076;
    rom[39] = 16'h8180;
    rom[40] = 16'h8288;
    rom[41] = 16'h838F;
    rom[42] = 16'h8496;
    rom[43] = 16'h85A3;
    rom[44] = 16'h86AF;
    rom[45] = 16'h87C4;
    rom[46] = 16'h88D7;
    rom[47] = 16'h89E8;
    rom[48] = 16'h13E7; // COM8:  re-enable AWB/AEC/AGC
    rom[49] = 16'h0F4B; // COM6
    rom[50] = 16'h1601;
    rom[51] = 16'h2102;
    rom[52] = 16'h2291;
    rom[53] = 16'h2907;
    rom[54] = 16'h330B;
    rom[55] = 16'h350B;
    rom[56] = 16'h371D;
    rom[57] = 16'h3871;
    rom[58] = 16'h392A;
    rom[59] = 16'h3C78;
    rom[60] = 16'h4D40;
    rom[61] = 16'h4E20;
    rom[62] = 16'h6900; // GFIX
    // [F2] was 6B4A — PLL×4 raised internal clock to 100 MHz and could
    //      push PCLK to 50 MHz, causing missed pixels in the capture logic
    rom[63] = 16'h6B0A; // DBLV: bypass PLL, PCLK = xclk = 25 MHz
    rom[64] = 16'h7410;
    rom[65] = 16'h8D4F;
    rom[66] = 16'h8E00;
    rom[67] = 16'h8F00;
    rom[68] = 16'h9000;
    rom[69] = 16'h9100;
    rom[70] = 16'h9600;
    rom[71] = 16'h9A00;
    rom[72] = 16'hB084;
    rom[73] = 16'hB10C;
    rom[74] = 16'hFFFF; // end marker
end

// ---- SCCB 3-phase write FSM ----
// Each write: START | dev_addr(0x42) | reg_addr | data | STOP
localparam OV_ADDR  = 8'h42;
localparam S_DELAY  = 4'd0,  // startup hold after reset
           S_NEXT   = 4'd1,  // load next ROM entry
           S_START  = 4'd2,  // generate START condition
           S_ADDR   = 4'd3,  // send device address byte + don't-care ACK
           S_REG    = 4'd4,  // send register address byte + don't-care ACK
           S_DATA   = 4'd5,  // send data byte + don't-care ACK
           S_STOP   = 4'd6,  // generate STOP condition
           S_DONE   = 4'd7;  // all registers written, hold idle

reg [3:0]  state    = S_DELAY;
reg [7:0]  rom_idx  = 0;
reg [23:0] shift;           // {dev_addr, reg_addr, data}
reg [4:0]  bit_cnt;
reg [1:0]  stop_ph;
reg        siod_out = 1;
reg        siod_oe  = 1;
reg [19:0] delay_cnt = 0;

// SCCB allows slave to not pull SDA during ACK slot (don't-care)
// so we never need to read siod — just release it for one bit.
assign siod = siod_oe ? siod_out : 1'bz;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        state     <= S_DELAY;
        sioc      <= 1'b1;
        siod_out  <= 1'b1;
        siod_oe   <= 1'b1;
        done      <= 1'b0;
        rom_idx   <= 0;
        delay_cnt <= 0;
        bit_cnt   <= 0;
        stop_ph   <= 0;
    end else begin
        done <= 1'b0;

        case (state)

        // ---- Wait ~10 ms for OV7670 to power up before first write ----
        S_DELAY: begin
            sioc <= 1; siod_out <= 1; siod_oe <= 1;
            if (sccb_tick) begin
                delay_cnt <= delay_cnt + 1;
                if (delay_cnt == 20'hFFFFF) state <= S_NEXT;
            end
        end

        S_NEXT: begin
            if (rom[rom_idx] == 16'hFFFF) state <= S_DONE;
            else begin
                shift   <= {OV_ADDR, rom[rom_idx]};
                bit_cnt <= 0;
                state   <= S_START;
            end
        end

        // ---- START: SDA high→low while SCL high ----
        S_START: begin
            if (sccb_tick) case (phase)
                2'd0: begin sioc <= 1; siod_out <= 1; siod_oe <= 1; end
                2'd1: begin siod_out <= 0; end
                2'd2: begin sioc <= 0; end
                2'd3: begin state <= S_ADDR; bit_cnt <= 0; end
            endcase
        end

        // ---- Device address byte (8 bits) + 1 don't-care ACK slot ----
        S_ADDR: begin
            if (sccb_tick) case (phase)
                2'd0: begin
                    if (bit_cnt < 8) siod_out <= shift[23];
                    else             siod_oe  <= 0;       // release for ACK
                end
                2'd1: sioc <= 1;
                2'd2: sioc <= 0;
                2'd3: begin
                    if (bit_cnt < 8) begin
                        shift   <= {shift[22:0], 1'b0};
                        bit_cnt <= bit_cnt + 1;
                    end else begin
                        siod_oe <= 1;
                        bit_cnt <= 0;
                        shift   <= {8'h00, rom[rom_idx]};
                        state   <= S_REG;
                    end
                end
            endcase
        end

        // ---- Register address byte + don't-care ACK ----
        S_REG: begin
            if (sccb_tick) case (phase)
                2'd0: begin
                    if (bit_cnt < 8) siod_out <= shift[15];
                    else             siod_oe  <= 0;
                end
                2'd1: sioc <= 1;
                2'd2: sioc <= 0;
                2'd3: begin
                    if (bit_cnt < 8) begin
                        shift   <= {shift[22:0], 1'b0};
                        bit_cnt <= bit_cnt + 1;
                    end else begin
                        siod_oe <= 1;
                        bit_cnt <= 0;
                        state   <= S_DATA;
                    end
                end
            endcase
        end

        // ---- Data byte + don't-care ACK ----
        S_DATA: begin
            if (sccb_tick) case (phase)
                2'd0: begin
                    if (bit_cnt < 8) siod_out <= shift[7];
                    else             siod_oe  <= 0;
                end
                2'd1: sioc <= 1;
                2'd2: sioc <= 0;
                2'd3: begin
                    if (bit_cnt < 8) begin
                        shift   <= {shift[22:0], 1'b0};
                        bit_cnt <= bit_cnt + 1;
                    end else begin
                        siod_oe <= 1;
                        bit_cnt <= 0;
                        state   <= S_STOP;
                        stop_ph <= 0;
                    end
                end
            endcase
        end

        // ---- STOP: SDA low→high while SCL high ----
        S_STOP: begin
            if (sccb_tick) case (stop_ph)
                2'd0: begin sioc <= 0; siod_out <= 0; siod_oe <= 1; stop_ph <= 1; end
                2'd1: begin sioc <= 1;                               stop_ph <= 2; end
                2'd2: begin siod_out <= 1;                           stop_ph <= 3; end
                2'd3: begin rom_idx <= rom_idx + 1; state <= S_NEXT; end
            endcase
        end

        S_DONE: begin
            done     <= 1'b1;
            sioc     <= 1'b1;
            siod_out <= 1'b1;
            siod_oe  <= 1'b1;
        end

        default: state <= S_DELAY;
        endcase
    end
end

endmodule
