`timescale 1ns / 1ps
module osd_text_char_rom(input wire clka, input wire [8:0] addra, output wire [6:0] doa);
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(7), .ADDR_WIDTH_A(9), .DATA_DEPTH_A(272),
        .DATA_WIDTH_B(7), .ADDR_WIDTH_B(9), .DATA_DEPTH_B(272),
        .MODE("SP"), .REGMODE_A("NOREG"), .IMPLEMENT("9K"),
        .DEBUGGABLE("NO"), .PACKABLE("NO"), .INIT_FILE("text_characters.mif"),
        .FILL_ALL("NONE")
    ) inst (
        .dia(7'd0), .dib(7'd0), .addra(addra), .addrb(9'd0),
        .cea(1'b1), .ceb(1'b0), .ocea(1'b0), .oceb(1'b0),
        .clka(clka), .clkb(1'b0), .wea(1'b0), .web(1'b0),
        .bea(1'b0), .beb(1'b0), .rsta(1'b0), .rstb(1'b0),
        .doa(doa), .dob()
    );
endmodule