module video_bgm_spectrum_height_bram (
    input  wire       clk,
    input  wire       write_enable,
    input  wire [6:0] write_address,
    input  wire [3:0] write_data,
    input  wire       read_enable,
    input  wire [6:0] read_address,
    output wire [3:0] read_data
);

    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(4),
        .ADDR_WIDTH_A(7),
        .DATA_DEPTH_A(128),
        .DATA_WIDTH_B(4),
        .ADDR_WIDTH_B(7),
        .DATA_DEPTH_B(128),
        .MODE("DP"),
        .REGMODE_A("NOREG"),
        .REGMODE_B("NOREG"),
        .IMPLEMENT("9K"),
        .DEBUGGABLE("NO"),
        .PACKABLE("NO"),
        .INIT_FILE("NONE"),
        .FILL_ALL("NONE")
    ) inst (
        .dia(4'd0),
        .dib(write_data),
        .addra(read_address),
        .addrb(write_address),
        .cea(read_enable),
        .ceb(write_enable),
        .ocea(1'b0),
        .oceb(1'b0),
        .clka(clk),
        .clkb(clk),
        .wea(1'b0),
        .web(write_enable),
        .bea(1'b0),
        .beb(1'b1),
        .rsta(1'b0),
        .rstb(1'b0),
        .doa(read_data),
        .dob()
    );

endmodule
