`timescale 1ns/1ps
module panel_img_delta_rom(input wire clk, input wire ce, input wire [14:0] addr, output wire [7:0] dout);
EG_LOGIC_BRAM #(.DATA_WIDTH_A(8),.ADDR_WIDTH_A(15),.DATA_DEPTH_A(24576),
.DATA_WIDTH_B(8),.ADDR_WIDTH_B(15),.DATA_DEPTH_B(24576),.MODE("SP"),
.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("32K"),.DEBUGGABLE("NO"),.PACKABLE("NO"),
.INIT_FILE("panel_img_delta.mif"),.FILL_ALL("NONE")) inst (
.dia(8'd0),.dib(8'd0),.addra(addr),.addrb(15'd0),
.cea(ce),.ceb(1'b0),.ocea(1'b0),.oceb(1'b0),.clka(clk),.clkb(clk),
.wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(dout),.dob());
endmodule
