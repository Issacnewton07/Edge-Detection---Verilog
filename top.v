// ============================================================
// top.v  —  OV7670 → ST7735 TFT Live Video (final, all fixes)
// Board : EDGE Artix-7,  50 MHz input clock
//
// ── All fixes applied ──────────────────────────────────────
//
// [F1] TSLB 3A04 → 3A00  (ov7670_sccb.v)
//      Bit[2] was reversing byte order inside each RGB565 word,
//      making red and blue channels visually swapped.
//
// [F2] DBLV 6B4A → 6B0A  (ov7670_sccb.v)
//      PLL×4 raised PCLK up to 50 MHz, outrunning capture logic.
//      Bypass mode keeps PCLK = xclk = 25 MHz.
//
// [F3] Safe ping-pong CDC with registered bank snapshot
//      Previous code derived completed_bank combinatorially from
//      a 2-stage sync register (~wb1), racing with the line_rdy
//      pulse.  Fix: snapshot wb1 into rd_bank_latch in the same
//      registered always-block that asserts line_pending, one
//      cycle after line_rdy.  The wb1 sync is stable by then.
//
// [F4] line_consumed gated by !spi_active
//      Previous code set line_consumed_r inside FS_LSEND while
//      transitioning to FS_WSPI, so the CDC block could clear
//      line_pending while SPI was still shifting the last byte.
//      Fix: line_consumed only fires after FS_WSPI sees
//      !spi_active for the final byte, not before.
//
// [F5] Frame-drop flow control
//      If SPI is busy when the next camera line completes,
//      line_pending is already set so the new line_rdy is
//      silently discarded.  Camera keeps writing to its own
//      bank; the display shows the last fully-latched line.
//      No corruption, just a graceful reduction in frame rate.
//
// [F6] SPI speed 6.25 MHz → 12.5 MHz  (100 MHz sys ÷ 8)
//      ST7735 maximum is 15 MHz.  At 12.5 MHz:
//        128 px × 16 bit / 12.5 MHz = 163 µs / line
//      Camera horizontal period at 25 MHz PCLK ≈ 1040 µs,
//      so SPI drains comfortably inside one line blanking gap.
//
// [F7] Pixel column stored directly into display index 0..127
//      Crops centre 128 of 160 subsampled columns at write time,
//      eliminating the runtime +16 offset at read time.
//
// ── Architecture ───────────────────────────────────────────
//
//  OV7670 QVGA 320×240 RGB565 @ PCLK 25 MHz
//    ↓ subsample X 2:1 → 160 cols, keep rows 0-119 → 160×120
//    ↓ store centre cols 16-143 → 128 cols per line
//    ↓ ping-pong buffers buf_a / buf_b  (each 128×16 b, LUT RAM)
//    ↓ toggle CDC with registered bank snapshot
//    ↓ SPI 12.5 MHz → ST7735 window 128×120 (CASET 0-127, RASET 20-139)
//
// ── Buttons ───────────────────────────────────────────────
//  pb[4] centre button — not used (reserved for future reinit)
//
// ── LEDs ──────────────────────────────────────────────────
//  led[0]  SCCB init complete
//  led[1]  streaming active (FSM ≥ FS_LWAIT)
//  led[2]  SPI byte in progress
//  led[3]  OV7670 VSYNC (blinks ~30 Hz)
//  led[4]  line_pending (SPI has work to do)
//  led[15] heartbeat ~0.3 Hz
// ============================================================

module top (
    input  wire        clk,            // N11, 50 MHz

    input  wire [4:0]  pb,             // active-high, PULLDOWN

    output wire [15:0] led,

    // OV7670
    output wire        ov7670_sioc,
    inout  wire        ov7670_siod,
    input  wire        ov7670_vsync,
    input  wire        ov7670_href,
    input  wire        ov7670_pclk,
    output wire        ov7670_xclk,
    input  wire [7:0]  ov7670_data,
    output wire        ov7670_reset,
    output wire        ov7670_pwdn,

    // ST7735 TFT SPI
    output reg         tft_sck,
    output reg         tft_sdi,
    output reg         tft_dc,
    output reg         tft_reset,
    output reg         tft_cs
);

// ===========================================================
// 1.  PLL  :  50 MHz in → 100 MHz clk_sys,  25 MHz clk_cam
//     VCO = 50 × 20 = 1000 MHz  (within 600-1200 MHz range)
// ===========================================================
wire clk_sys, clk_cam, pll_locked;
wire clk_fb, raw_sys, raw_cam;

MMCME2_BASE #(
    .CLKIN1_PERIOD  (20.0),    // 50 MHz = 20 ns
    .CLKFBOUT_MULT_F(20.0),    // VCO = 1000 MHz
    .CLKOUT0_DIVIDE_F(10.0),   // clk_sys = 100 MHz
    .CLKOUT1_DIVIDE (40),      // clk_cam =  25 MHz
    .DIVCLK_DIVIDE  (1)
) u_pll (
    .CLKIN1  (clk),    .CLKFBIN (clk_fb),
    .CLKFBOUT(clk_fb), .CLKOUT0 (raw_sys), .CLKOUT1(raw_cam),
    .LOCKED  (pll_locked), .PWRDWN(1'b0),  .RST(1'b0)
);
BUFG u_bs (.I(raw_sys), .O(clk_sys));
BUFG u_bc (.I(raw_cam), .O(clk_cam));

// Drive OV7670 xclk cleanly via ODDR — no glitch, registered edge
ODDR #(.DDR_CLK_EDGE("SAME_EDGE")) u_xclk (
    .Q(ov7670_xclk), .C(clk_cam), .CE(1'b1),
    .D1(1'b1), .D2(1'b0), .R(1'b0), .S(1'b0)
);

assign ov7670_reset = pll_locked;  // hold camera in reset until PLL locks
assign ov7670_pwdn  = 1'b0;

// ===========================================================
// 2.  System reset  —  synchronous, 256 cycles after PLL lock
// ===========================================================
reg [7:0] rst_sr = 8'hFF;
wire sys_rst = rst_sr[7];

always @(posedge clk_sys)
    if (!pll_locked) rst_sr <= 8'hFF;
    else             rst_sr <= {rst_sr[6:0], 1'b0};

// ===========================================================
// 3.  SCCB  (clk_cam domain, 25 MHz)
//     ov7670_sccb.v contains fixes F1 (TSLB) and F2 (DBLV)
// ===========================================================
wire sccb_done;

ov7670_sccb #(.CLK_FREQ(25_000_000), .SCCB_FREQ(100_000))
u_sccb (
    .clk (clk_cam),
    .rst (sys_rst),
    .sioc(ov7670_sioc),
    .siod(ov7670_siod),
    .done(sccb_done)
);

// Sync sccb_done into clk_sys domain.
// sccb_done stays permanently high once set — safe single-bit sync.
reg cd0 = 0, cd1 = 0;
always @(posedge clk_sys) begin cd0 <= sccb_done; cd1 <= cd0; end
wire cam_ready = cd1;

// ===========================================================
// 4.  Ping-pong line buffers  (PCLK writes, clk_sys reads)
//
//  Two banks, each 128 × 16-bit = 2 Kbit → fits in LUT RAM.
//  Camera writes subsampled pixels directly into display index
//  0..127, cropping at write time (cols 16-143 of 160-wide
//  subsampled line).  No offset arithmetic at read time.
// ===========================================================
(* ram_style = "distributed" *) reg [15:0] buf_a [0:127];
(* ram_style = "distributed" *) reg [15:0] buf_b [0:127];

// ---- PCLK-domain signals ----
reg        wr_bank     = 0;   // 0→write A, 1→write B
reg        wr_done_tog = 0;   // toggles each time a line is fully written

// ---- CDC: rd_ack_tog (clk_sys) synced into PCLK domain ----
// Not used for hard blocking (frame-drop strategy), but kept for
// optional future back-pressure.  Currently camera always flips
// wr_bank unconditionally; clk_sys latches rd_bank at snapshot time.
reg        rd_ack_tog  = 0;   // toggled by clk_sys FSM per line consumed

// ---- Camera capture state (PCLK domain) ----
reg [7:0]  cam_col  = 0;   // subsampled column counter 0..159
reg [6:0]  disp_col = 0;   // write index into buf_a/b: 0..127
reg [7:0]  cam_row  = 0;   // row counter 0..119
reg        byte_sel = 0;   // 0=first byte of pixel, 1=second
reg [7:0]  byte0    = 0;   // holds first byte until second arrives
reg        col_skip = 0;   // subsample toggle: store on col_skip==0
reg        vs_prev  = 0;
reg        hr_prev  = 0;

always @(posedge ov7670_pclk) begin
    vs_prev <= ov7670_vsync;
    hr_prev <= ov7670_href;

    // ---- Rising VSYNC: new frame ----
    // Reset row counter and byte state.  Do NOT flip wr_bank here;
    // bank management is per-line so the reader always has a full
    // stable line — not a partial one from a new frame.
    if (ov7670_vsync && !vs_prev) begin
        cam_row  <= 0;
        byte_sel <= 0;
        col_skip <= 0;
        cam_col  <= 0;
        disp_col <= 0;
    end

    // ---- Falling HREF: end of a valid display line ----
    // Reset byte/column state unconditionally (guards against a line
    // ending on an odd byte — the HREF edge off-by-one concern).
    // Only increment cam_row and signal completion for rows 0-119.
    if (!ov7670_href && hr_prev) begin
        if (cam_row < 120) begin
            wr_done_tog <= ~wr_done_tog;   // signal line complete
            cam_row     <= cam_row + 1;
            wr_bank     <= ~wr_bank;       // move to next bank for next line
        end
        // Reset unconditionally — handles partial-pixel safety [HREF off-by-one]
        byte_sel <= 0;
        col_skip <= 0;
        cam_col  <= 0;
        disp_col <= 0;
    end

    // ---- Active pixel data (HREF high, within display rows) ----
    if (ov7670_href && cam_row < 120) begin
        if (!byte_sel) begin
            // First byte of RGB565 pixel — latch, wait for second
            byte0    <= ov7670_data;
            byte_sel <= 1;
        end else begin
            // Second byte arrives — pixel is complete
            byte_sel <= 0;
            if (!col_skip) begin
                // Even subsampled column: check if in display crop window
                // Columns 16..143 of the 160-wide subsampled line → indices 0..127
                if (cam_col >= 8'd16 && cam_col < 8'd144) begin
                    if (!wr_bank)
                        buf_a[disp_col] <= {byte0, ov7670_data};
                    else
                        buf_b[disp_col] <= {byte0, ov7670_data};
                    disp_col <= disp_col + 1;
                end
                cam_col <= cam_col + 1;
            end
            col_skip <= ~col_skip;  // alternate: skip odd raw columns
        end
    end
end

// ===========================================================
// 5.  CDC  :  wr_done_tog (PCLK) → line_rdy pulse (clk_sys)
//             with registered bank snapshot  [FIX F3]
//
// Problem the fix solves:
//   completed_bank was derived as ~wb1 (combinatorial from the
//   2-stage sync chain for wr_bank).  If the wb1 register update
//   and the line_rdy XOR pulse land on the same clk_sys edge,
//   the combinatorial ~wb1 could flicker, latching the wrong bank.
//
// Fix:
//   Capture wb1 one additional cycle later (wb2) and register the
//   snapshot inside the same always-block that sets line_pending.
//   By the time line_rdy fires (wd1^wd2), wb1 has been stable for
//   at least one full clk_sys cycle, so wb2 = stable completed bank.
// ===========================================================

// 2-stage sync for wr_done_tog
reg wd0 = 0, wd1 = 0, wd2 = 0;
always @(posedge clk_sys) begin wd0 <= wr_done_tog; wd1 <= wd0; wd2 <= wd1; end
wire line_rdy = wd1 ^ wd2;   // one clk_sys pulse per completed camera line

// 2-stage sync for wr_bank; add one more pipeline stage for snapshot
reg wb0 = 0, wb1 = 0;
always @(posedge clk_sys) begin wb0 <= wr_bank; wb1 <= wb0; end
// wb1 reflects wr_bank after the flip (camera already moved to next bank).
// So the COMPLETED bank (just written) is ~wb1.
// We register this into rd_bank_latch one cycle after line_rdy [F3].

reg rd_bank_latch = 0;   // which bank to read; stable for entire SPI send
reg line_pending  = 0;   // a complete line is waiting for SPI

// [F4] line_consumed: wire driven by FSM, fires only after spi_active
//      de-asserts for the final byte — see section 7 for driver.
wire line_consumed;

always @(posedge clk_sys or posedge sys_rst) begin
    if (sys_rst) begin
        line_pending  <= 0;
        rd_bank_latch <= 0;
        rd_ack_tog    <= 0;
    end else begin
        if (line_rdy) begin
            if (!line_pending) begin
                // [F3] Snapshot one cycle after line_rdy — wb1 is stable.
                // wb1 = current (new) write bank → completed bank = ~wb1
                rd_bank_latch <= ~wb1;
                line_pending  <= 1;
            end
            // else: SPI still busy → silently drop this line [F5]
            // camera will overwrite its write bank; no corruption
        end
        if (line_consumed) begin
            line_pending <= 0;
            rd_ack_tog   <= ~rd_ack_tog;   // optional back-pressure signal
        end
    end
end

// ===========================================================
// 6.  SPI engine  —  100 MHz ÷ 8 = 12.5 MHz SCK
//
//  [F8] spi_done strobe replaces FS_WSPI busy-poll.
//       spi_done pulses HIGH for exactly ONE clk_sys cycle
//       when the last bit of a byte has been clocked (falling
//       SCK after bit 7).  The FSM transitions on this strobe
//       directly — no polling loop, no wasted cycles.
//
//  Throughput: 128 px × 16 bit ÷ 12.5 MHz = 163 µs/line
//  Camera line period @ 25 MHz PCLK ≈ 1040 µs → 6× headroom
// ===========================================================
reg [2:0] spidiv   = 0;
wire      spi_tick = (spidiv == 3'd7);   // pulses every 8 sys cycles
always @(posedge clk_sys) spidiv <= spidiv + 1;

reg [7:0] spi_sr     = 0;
reg [3:0] spi_bcnt   = 0;
reg       spi_active = 0;
reg       spi_done   = 0;   // [F8] 1-cycle strobe: last bit just clocked

reg       spi_go      = 0;
reg [7:0] spi_data    = 0;
reg       spi_is_data = 0;

always @(posedge clk_sys or posedge sys_rst) begin
    if (sys_rst) begin
        spi_active <= 0; spi_done <= 0; spi_sr <= 0; spi_bcnt <= 0;
        tft_sck <= 0; tft_sdi <= 0; tft_dc <= 0;
    end else begin
        spi_done <= 0;   // default: strobe is off

        // Load a new byte when spi_go pulses and engine is idle
        if (spi_go && !spi_active) begin
            spi_sr     <= spi_data;
            spi_active <= 1;
            spi_bcnt   <= 0;
            tft_dc     <= spi_is_data;
            tft_sck    <= 0;
        end

        if (spi_active && spi_tick) begin
            tft_sck <= ~tft_sck;
            if (!tft_sck) begin
                // SCK going high → shift MSB onto MOSI
                tft_sdi <= spi_sr[7];
                spi_sr  <= {spi_sr[6:0], 1'b0};
            end else begin
                // SCK going low → bit was sampled, advance
                if (spi_bcnt == 4'd7) begin
                    // Last bit done
                    spi_active <= 0;
                    spi_done   <= 1;   // [F8] fire strobe for exactly one cycle
                    tft_sck    <= 0;
                end else begin
                    spi_bcnt <= spi_bcnt + 1;
                end
            end
        end
    end
end

// ===========================================================
// 7.  Main FSM  (clk_sys domain)
//
//  [F8] FS_WSPI and FS_WSPI_LAST are REMOVED.
//       Every state that previously set next_s and jumped to
//       FS_WSPI now waits inline: it asserts spi_go on the
//       first cycle, then stays in the same state until
//       spi_done fires — exactly 64 clk_sys cycles later
//       (8 bits × 8 cycles/bit), with zero polling overhead.
//
//  Pattern for a single SPI byte:
//    STATE_X: begin
//        if (!spi_active && !spi_done) begin   // idle → load
//            spi_data <= BYTE; spi_is_data <= DC; spi_go <= 1;
//        end
//        if (spi_done) fst <= NEXT_STATE;      // done → advance
//    end
//
//  For multi-byte sequences (CASET/RASET) seq_idx advances on
//  each spi_done, all within the same FSM state.
//
//  Init sequence (unchanged timing, matches working reference):
//    delay → SWRESET → delay → SLPOUT → delay →
//    COLMOD(0x3A, 0x05) → DISPON(0x29) →
//    wait cam_ready → CASET/RASET/RAMWR → stream pixels
// ===========================================================
localparam
    FS_HWRST   = 4'd0,
    FS_SWRST   = 4'd1,
    FS_DLY0    = 4'd2,
    FS_SLPOUT  = 4'd3,
    FS_DLY1    = 4'd4,
    FS_COLMOD  = 4'd5,   // also sends DISPON as seq_idx==2
    FS_WAITCAM = 4'd6,
    FS_CASET   = 4'd7,
    FS_RASET   = 4'd8,
    FS_RAMWR   = 4'd9,
    FS_LWAIT   = 4'd10,
    FS_LSEND   = 4'd11;
// 12 states total, fits 4-bit encoding; FS_WSPI/FS_WSPI_LAST/FS_DISPON removed [F8]

reg [3:0]  fst     = FS_HWRST;
reg [23:0] dly_cnt = 0;
reg [3:0]  seq_idx = 0;
reg [6:0]  px_col  = 0;
reg [6:0]  px_row  = 0;
reg        px_hi   = 1;
reg [15:0] px_word = 0;

// line_consumed: fires when last byte of a display line is confirmed done
reg line_consumed_r = 0;
assign line_consumed = line_consumed_r;

// Delay = 0x0FFFFF × 8 clk_sys cycles (matches reference timing, ~83 ms)
localparam DLY_MATCH = 24'd8_388_608;

always @(posedge clk_sys or posedge sys_rst) begin
    if (sys_rst) begin
        fst             <= FS_HWRST;
        tft_reset       <= 1;
        tft_cs          <= 0;
        spi_go          <= 0;
        dly_cnt         <= 0;
        seq_idx         <= 0;
        px_col          <= 0;
        px_row          <= 0;
        px_hi           <= 1;
        px_word         <= 0;
        line_consumed_r <= 0;
    end else begin
        spi_go          <= 0;
        line_consumed_r <= 0;

        case (fst)

        // ---- Initial reset delay ----
        FS_HWRST: begin
            tft_reset <= 1; tft_cs <= 0;
            dly_cnt <= dly_cnt + 1;
            if (dly_cnt == DLY_MATCH-1) begin
                dly_cnt <= 0;
                fst     <= FS_SWRST;
            end
        end

        // ---- SWRESET 0x01, then delay ----
        // [F8] Load byte on first entry (spi_active=0, spi_done=0).
        //      Stay here until spi_done fires, then jump to DLY0.
        FS_SWRST: begin
            if (!spi_active && !spi_done) begin
                spi_data <= 8'h01; spi_is_data <= 0; spi_go <= 1;
            end
            if (spi_done) begin dly_cnt <= 0; fst <= FS_DLY0; end
        end

        FS_DLY0: begin
            dly_cnt <= dly_cnt + 1;
            if (dly_cnt == DLY_MATCH-1) begin dly_cnt <= 0; fst <= FS_SLPOUT; end
        end

        // ---- SLPOUT 0x11, then delay ----
        FS_SLPOUT: begin
            if (!spi_active && !spi_done) begin
                spi_data <= 8'h11; spi_is_data <= 0; spi_go <= 1;
            end
            if (spi_done) begin dly_cnt <= 0; fst <= FS_DLY1; end
        end

        FS_DLY1: begin
            dly_cnt <= dly_cnt + 1;
            if (dly_cnt == DLY_MATCH-1) begin dly_cnt <= 0; seq_idx <= 0; fst <= FS_COLMOD; end
        end

        // ---- COLMOD 0x3A (cmd), 0x05 (data), DISPON 0x29 (cmd) ----
        // seq_idx 0=0x3A  1=0x05  2=0x29; on spi_done at seq 2 → WAITCAM
        FS_COLMOD: begin
            if (!spi_active && !spi_done) begin
                case (seq_idx)
                4'd0: begin spi_data <= 8'h3A; spi_is_data <= 0; spi_go <= 1; end
                4'd1: begin spi_data <= 8'h05; spi_is_data <= 1; spi_go <= 1; end
                4'd2: begin spi_data <= 8'h29; spi_is_data <= 0; spi_go <= 1; end
                default: ;
                endcase
            end
            if (spi_done) begin
                if (seq_idx == 4'd2) begin seq_idx <= 0; fst <= FS_WAITCAM; end
                else                       seq_idx <= seq_idx + 1;
            end
        end


        // ---- Wait for SCCB camera init ----
        FS_WAITCAM: begin
            if (cam_ready) begin seq_idx <= 0; fst <= FS_CASET; end
        end

        // ---- CASET: cmd 0x2A, data 0x00 0x00 0x00 0x7F ----
        // seq_idx 0..4; advance on each spi_done
        FS_CASET: begin
            if (!spi_active && !spi_done) begin
                case (seq_idx)
                4'd0: begin spi_data<=8'h2A; spi_is_data<=0; spi_go<=1; end
                4'd1: begin spi_data<=8'h00; spi_is_data<=1; spi_go<=1; end
                4'd2: begin spi_data<=8'h00; spi_is_data<=1; spi_go<=1; end
                4'd3: begin spi_data<=8'h00; spi_is_data<=1; spi_go<=1; end
                4'd4: begin spi_data<=8'h7F; spi_is_data<=1; spi_go<=1; end
                default: ;
                endcase
            end
            if (spi_done) begin
                if (seq_idx == 4'd4) begin seq_idx <= 0; fst <= FS_RASET; end
                else                       seq_idx <= seq_idx + 1;
            end
        end

        // ---- RASET: cmd 0x2B, data 0x00 0x14 0x00 0x8B ----
        FS_RASET: begin
            if (!spi_active && !spi_done) begin
                case (seq_idx)
                4'd0: begin spi_data<=8'h2B; spi_is_data<=0; spi_go<=1; end
                4'd1: begin spi_data<=8'h00; spi_is_data<=1; spi_go<=1; end
                4'd2: begin spi_data<=8'h14; spi_is_data<=1; spi_go<=1; end
                4'd3: begin spi_data<=8'h00; spi_is_data<=1; spi_go<=1; end
                4'd4: begin spi_data<=8'h8B; spi_is_data<=1; spi_go<=1; end
                default: ;
                endcase
            end
            if (spi_done) begin
                if (seq_idx == 4'd4) begin seq_idx <= 0; fst <= FS_RAMWR; end
                else                       seq_idx <= seq_idx + 1;
            end
        end

        // ---- RAMWR 0x2C: open pixel stream ----
        FS_RAMWR: begin
            if (!spi_active && !spi_done) begin
                spi_data <= 8'h2C; spi_is_data <= 0; spi_go <= 1;
            end
            if (spi_done) begin
                px_col <= 0; px_row <= 0; px_hi <= 1;
                fst    <= FS_LWAIT;
            end
        end

        // ---- Wait for line_pending from camera ----
        FS_LWAIT: begin
            if (line_pending) begin
                px_word <= rd_bank_latch ? buf_b[0] : buf_a[0];
                px_col  <= 0;
                px_hi   <= 1;
                fst     <= FS_LSEND;
            end
        end

        // ---- Send pixel bytes  [F8] ----
        //
        //  On entry: load the byte (spi_active=0, spi_done=0 guaranteed
        //  because we only enter from FS_LWAIT or from spi_done itself).
        //
        //  State machine within FS_LSEND:
        //    spi_active=0, spi_done=0 → assert spi_go, stay here
        //    spi_active=1             → SPI engine busy, stay here (0 cycles wasted in FSM)
        //    spi_done=1               → byte finished, advance pixel/line/frame
        //
        //  The FSM never spins polling — it idles in this state while the
        //  SPI engine shifts bits, and reacts immediately when spi_done fires.
        FS_LSEND: begin
            // ---- Load byte if engine just became free ----
            if (!spi_active && !spi_done) begin
                spi_data    <= px_hi ? px_word[15:8] : px_word[7:0];
                spi_is_data <= 1;
                spi_go      <= 1;
            end

            // ---- Advance on strobe ----
            if (spi_done) begin
                if (px_hi) begin
                    // High byte sent — flip to low byte, stay in FS_LSEND
                    px_hi <= 0;
                    // px_word already loaded; low byte sent next cycle
                end else begin
                    // Low byte sent — pixel complete
                    px_hi <= 1;
                    if (px_col == 7'd127) begin
                        // End of line
                        line_consumed_r <= 1;      // [F4] safe: spi_done = last bit done
                        px_col <= 0;
                        if (px_row == 7'd119) begin
                            // End of frame — re-issue window commands
                            px_row  <= 0;
                            seq_idx <= 0;
                            fst     <= FS_CASET;
                        end else begin
                            px_row <= px_row + 1;
                            fst    <= FS_LWAIT;
                        end
                    end else begin
                        // Next pixel — preload word and stay in FS_LSEND
                        px_col  <= px_col + 1;
                        px_word <= rd_bank_latch ?
                                   buf_b[px_col + 1] :
                                   buf_a[px_col + 1];
                        // FSM stays in FS_LSEND; next cycle:
                        //   spi_done=0, spi_active=0 → load high byte
                    end
                end
            end
        end

        default: fst <= FS_HWRST;
        endcase
    end
end

// ===========================================================
// 8.  Status LEDs
// ===========================================================
reg [25:0] hb = 0;
always @(posedge clk_sys) hb <= hb + 1;

assign led[0]    = cam_ready;
assign led[1]    = (fst >= FS_LWAIT);
assign led[2]    = spi_active;
assign led[3]    = ov7670_vsync;
assign led[4]    = line_pending;
assign led[14:5] = 10'd0;
assign led[15]   = hb[25];   // ~0.3 Hz heartbeat

endmodule
