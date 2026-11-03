module bgm_spectrum_sample_ram (
    input  wire        clk,
    input  wire        write_enable,
    input  wire [10:0] write_address,
    input  wire [7:0]  write_data,
    input  wire        read_enable,
    input  wire [10:0] read_address,
    output wire [7:0]  read_data
);

    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(8),
        .ADDR_WIDTH_A(11),
        .DATA_DEPTH_A(2048),
        .DATA_WIDTH_B(8),
        .ADDR_WIDTH_B(11),
        .DATA_DEPTH_B(2048),
        .MODE("DP"),
        .REGMODE_A("NOREG"),
        .REGMODE_B("NOREG"),
        .IMPLEMENT("9K"),
        .DEBUGGABLE("NO"),
        .PACKABLE("NO"),
        .INIT_FILE("NONE"),
        .FILL_ALL("NONE")
    ) inst (
        .dia(write_data),
        .dib(8'd0),
        .addra(write_address),
        .addrb(read_address),
        .cea(write_enable),
        .ceb(read_enable),
        .ocea(1'b0),
        .oceb(1'b0),
        .clka(clk),
        .clkb(clk),
        .wea(write_enable),
        .web(1'b0),
        .bea(1'b1),
        .beb(1'b0),
        .rsta(1'b0),
        .rstb(1'b0),
        .doa(),
        .dob(read_data)
    );

endmodule
