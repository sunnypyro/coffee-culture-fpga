`ifndef FOUR_GRID_PICKER_THUMBNAIL
`define FOUR_GRID_PICKER_THUMBNAIL
// F(u,v)=full(2u+1,2v+1), after accounting for BMP bottom-up stream rows.
module picker_thumbnail(
 input wire clk,rst,start,abort_job,in_valid,input wire[23:0]in_pixel,
 output wire out_valid,output wire[23:0]out_pixel,
 output reg done,output reg bad_count
);
 reg running;reg[9:0]x;reg[8:0]y;reg[16:0]count;
 assign out_valid=running&&!abort_job&&in_valid&&x[0]&&!y[0];
 assign out_pixel=in_pixel;
 always @(posedge clk or posedge rst)begin
  if(rst)begin running<=0;x<=0;y<=0;count<=0;done<=0;bad_count<=0;end
  else begin
   done<=0;
   if(abort_job)begin running<=0;x<=0;y<=0;count<=0;end
   else if(start)begin running<=1;x<=0;y<=0;count<=0;bad_count<=0;end
   else if(running&&in_valid)begin
    if(out_valid)count<=count+1'b1;
    if(x==639)begin
     x<=0;
     if(y==479)begin running<=0;done<=1;bad_count<=(count!=76800);end
     else y<=y+1'b1;
    end else x<=x+1'b1;
   end
  end
 end
endmodule
`endif
