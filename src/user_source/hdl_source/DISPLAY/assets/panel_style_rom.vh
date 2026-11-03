`timescale 1ns/1ps
module panel_style_rom(input wire clk, input wire ce, input wire [9:0] addr, output wire [8:0] dout, input wire [9:0] addrb, output wire [8:0] doutb);
EG_LOGIC_BRAM #(.DATA_WIDTH_A(9),.ADDR_WIDTH_A(10),.DATA_DEPTH_A(1024),
.DATA_WIDTH_B(9),.ADDR_WIDTH_B(10),.DATA_DEPTH_B(1024),.MODE("DP"),
.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("9K"),.DEBUGGABLE("NO"),.PACKABLE("NO"),
.INIT_FILE("panel_style.mif"),.FILL_ALL("NONE")) inst (
.dia(9'd0),.dib(9'd0),.addra(addr),.addrb(addrb),
.cea(ce),.ceb(ce),.ocea(1'b0),.oceb(1'b0),.clka(clk),.clkb(clk),
.wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(dout),.dob(doutb));
endmodule
