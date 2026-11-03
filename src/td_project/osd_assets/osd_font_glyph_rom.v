`timescale 1ns / 1ps
module osd_font_glyph_rom(input wire clka, input wire [14:0] addra, output wire [1:0] doa);
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(2), .ADDR_WIDTH_A(15), .DATA_DEPTH_A(25344),
        .DATA_WIDTH_B(2), .ADDR_WIDTH_B(15), .DATA_DEPTH_B(25344),
        .MODE("SP"), .REGMODE_A("NOREG"), .IMPLEMENT("9K"),
        .DEBUGGABLE("NO"), .PACKABLE("NO"), .INIT_FILE("font_glyphs.mif"),
        .FILL_ALL("NONE")
    ) inst (
        .dia(2'd0), .dib(2'd0), .addra(addra), .addrb(15'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clka), .clkb(1'b0), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
        .doa(doa), .dob()
    );
endmodule