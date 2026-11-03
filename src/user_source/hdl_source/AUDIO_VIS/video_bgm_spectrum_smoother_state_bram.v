module video_bgm_spectrum_smoother_state_bram (
    input  wire       clk,
    input  wire       read_enable,
    input  wire [5:0] read_address,
    output wire [3:0] read_data,
    input  wire       write_enable,
    input  wire [5:0] write_address,
    input  wire [3:0] write_data
);

    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(4),
        .ADDR_WIDTH_A(6),
        .DATA_DEPTH_A(64),
        .DATA_WIDTH_B(4),
        .ADDR_WIDTH_B(6),
        .DATA_DEPTH_B(64),
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
