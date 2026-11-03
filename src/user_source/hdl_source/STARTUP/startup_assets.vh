`ifndef F06_STARTUP_ASSETS_VH
`define F06_STARTUP_ASSETS_VH
// TD resolves INIT_FILE from this wrapper's source directory, not td_project.
// STARTUP/../../../td_project/startup_assets contains the startup MIFs.
// Keep 32K memories single-port: the target's DP mapping can duplicate blocks.
module f06_sp_memory #(
    parameter WIDTH=16, parameter AW=12, parameter DEPTH=2853,
    parameter IMPLEMENT="32K", parameter INIT_FILE="NONE"
)(
    input wire clk, input wire ce, input wire we,
    input wire [AW-1:0] addr, input wire [WIDTH-1:0] din,
    output wire [WIDTH-1:0] dout
);
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(WIDTH), .ADDR_WIDTH_A(AW), .DATA_DEPTH_A(DEPTH),
        .DATA_WIDTH_B(WIDTH), .ADDR_WIDTH_B(AW), .DATA_DEPTH_B(DEPTH),
        .MODE("SP"), .REGMODE_A("NOREG"), .IMPLEMENT(IMPLEMENT),
        .DEBUGGABLE("NO"), .PACKABLE("NO"), .INIT_FILE(INIT_FILE), .FILL_ALL("NONE")
    ) mem (
        .clka(clk), .clkb(1'b0), .cea(ce), .ceb(1'b0),
        .ocea(1'b0), .oceb(1'b0), .wea(we), .web(1'b0),
        .bea(1'b1), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
        .addra(addr), .addrb({AW{1'b0}}), .dia(din), .dib({WIDTH{1'b0}}),
        .doa(dout), .dob()
    );
endmodule

module f06_line_cache (
    input wire clk, input wire [6:0] read_addr, output wire [15:0] pixels,
    input wire we, input wire [6:0] write_addr, input wire [15:0] write_pixels
);
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(16), .ADDR_WIDTH_A(7), .DATA_DEPTH_A(128),
        .DATA_WIDTH_B(16), .ADDR_WIDTH_B(7), .DATA_DEPTH_B(128),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("9K"), .DEBUGGABLE("NO"), .PACKABLE("NO"),
        .INIT_FILE("../../../td_project/startup_assets/startup_line_zero.mif"), .FILL_ALL("NONE")
    ) mem (
        .clka(clk), .clkb(clk), .cea(1'b1), .ceb(we),
        .ocea(1'b0), .oceb(1'b0), .wea(1'b0), .web(we),
        .bea(1'b0), .beb(1'b1), .rsta(1'b0), .rstb(1'b0),
        .addra(read_addr), .addrb(write_addr), .dia(16'd0), .dib(write_pixels),
        .doa(pixels), .dob()
    );
endmodule
`endif
