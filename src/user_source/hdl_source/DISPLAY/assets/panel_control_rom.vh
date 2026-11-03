`timescale 1ns/1ps
module panel_control_rom(input wire clk, input wire ce, input wire [11:0] addr, output wire [15:0] dout);
EG_LOGIC_BRAM #(.DATA_WIDTH_A(16),.ADDR_WIDTH_A(12),.DATA_DEPTH_A(4096),
.DATA_WIDTH_B(16),.ADDR_WIDTH_B(12),.DATA_DEPTH_B(4096),.MODE("SP"),
.REGMODE_A("NOREG"),.REGMODE_B("NOREG"),.IMPLEMENT("32K"),.DEBUGGABLE("NO"),.PACKABLE("NO"),
.INIT_FILE("panel_control.mif"),.FILL_ALL("NONE")) inst (
.dia(16'd0),.dib(16'd0),.addra(addr),.addrb(12'd0),
.cea(ce),.ceb(1'b0),.ocea(1'b0),.oceb(1'b0),.clka(clk),.clkb(clk),
.wea(1'b0),.web(1'b0),.bea(1'b0),.beb(1'b0),.rsta(1'b0),.rstb(1'b0),.doa(dout),.dob());
endmodule
