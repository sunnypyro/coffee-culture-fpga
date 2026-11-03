// 16-bit audio view of the dedicated WAV audio FIFO.
//
// The frame-buffer path keeps using the soft-FIFO IP module
// rfifo_32_32_512 with its default 32-bit parameters.  The audio path
// must NOT override the parameters of that shared IP module any more:
// doing so made TD replace the IP netlist with a specialised copy
// (rfifo_16_16_512), after which the frame path's plain instantiation
// had no definition and became a black box (HDL-8007 at
// frame_read_write.v:144), which aborted synthesis.
//
// The audio path therefore uses its own plain-Verilog module
// wav_fifo_16_512, whose defaults are already 16-bit wide with
// show-ahead enabled, so no parameter override is needed here.
module audio_fifo_16 (
    input         rst,
    input         clkw,
    input         clkr,
    input         we,
    input  [15:0] di,
    input         re,
    output [15:0] dout,
    output        valid,
    output        full_flag,
    output        empty_flag,
    output        afull,
    output        aempty,
    output [8:0]  wrusedw,
    output [8:0]  rdusedw
);
    wav_fifo_16_512 u_fifo (
        .rst        (rst),
        .clkw       (clkw),
        .clkr       (clkr),
        .we         (we),
        .di         (di),
        .re         (re),
        .dout       (dout),
        .valid      (valid),
        .full_flag  (full_flag),
        .empty_flag (empty_flag),
        .afull      (afull),
        .aempty     (aempty),
        .wrusedw    (wrusedw),
        .rdusedw    (rdusedw)
    );
endmodule
