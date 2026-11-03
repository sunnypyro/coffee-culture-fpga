`ifndef FOUR_GRID_PICKER_STYLE
`define FOUR_GRID_PICKER_STYLE
module picker_style(
 input wire video_clk,rst,hs_in,vs_in,de_in,input wire[23:0]rgb_in,
 input wire[1:0]style,target_idx,
 output reg hs_out,vs_out,de_out,output reg[23:0]rgb_out
);
 reg[9:0]x;reg[8:0]y;reg vs_d,de_d;
 wire[1:0]quadrant={(y>=240),(x>=320)};
 wire dim=(style==1)||(style==3&&quadrant!=target_idx);
 wire[7:0]r=rgb_in[23:16],g=rgb_in[15:8],b=rgb_in[7:0];
 always @(posedge video_clk or posedge rst)begin
  if(rst)begin x<=0;y<=0;vs_d<=0;de_d<=0;hs_out<=0;vs_out<=0;de_out<=0;rgb_out<=0;end
  else begin
   vs_d<=vs_in;de_d<=de_in;hs_out<=hs_in;vs_out<=vs_in;de_out<=de_in;
   rgb_out<=dim?{(r-(r>>3)),(g-(g>>3)),(b-(b>>3))}:rgb_in;
   if(vs_d&&!vs_in)begin x<=0;y<=0;end
   else begin
    if(de_in)x<=x==639?0:x+1'b1;else x<=0;
    if(de_d&&!de_in)y<=y+1'b1;
   end
  end
 end
endmodule
`endif
