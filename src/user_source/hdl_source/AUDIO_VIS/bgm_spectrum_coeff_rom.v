module bgm_spectrum_coeff_rom (
    input  wire        clk,
    input  wire [5:0]  address,
    output wire [33:0] data
);

    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(34),
        .ADDR_WIDTH_A(6),
        .DATA_DEPTH_A(64),
        .DATA_WIDTH_B(34),
        .ADDR_WIDTH_B(6),
        .DATA_DEPTH_B(64),
        .MODE("SP"),
        .REGMODE_A("NOREG"),
        .IMPLEMENT("9K"),
        .DEBUGGABLE("NO"),
        .PACKABLE("NO"),
        .INIT_FILE("bgm_spectrum_coeff_64x34.mif"),
        .FILL_ALL("NONE")
    ) inst (
        .dia(34'd0),
        .dib(34'd0),
        .addra(address),
        .addrb(6'd0),
        .cea(1'b1),
        .ceb(1'b0),
        .ocea(1'b0),
        .oceb(1'b0),
        .clka(clk),
        .clkb(1'b0),
        .wea(1'b0),
        .web(1'b0),
        .bea(1'b0),
        .beb(1'b0),
        .rsta(1'b0),
        .rstb(1'b0),
        .doa(data),
        .dob()
    );

endmodule
