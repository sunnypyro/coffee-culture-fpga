`ifndef F11_RENDERER
`define F11_RENDERER
`include "assets/panel_contract.vh"
module hub75_renderer(
 input wire clk,rst,enable,input wire[5:0]x,input wire[4:0]row,
 input wire[3:0]top_index,bottom_index,input wire[15:0]font_data,
 input wire[`PANEL_STATE_W-1:0]render_state,
 input wire startup_mode,input wire[3:0]logo_data,input wire[6:0]diagonal_limit,
 input wire[5:0]text_edge,output wire[8:0]top_rgb,bottom_rgb,output wire valid
);
 reg[5:0]xq;reg[4:0]rowq;reg[1:0]valid_q;
 reg[8:0]logo_top,logo_bottom;
 function[8:0]logo_color;input[1:0]idx;input[5:0]px,py;
 begin
  if(idx==3)logo_color=px<=text_edge?9'h1ff:0;
  else if({1'b0,~px}+{1'b0,py}>diagonal_limit)logo_color=0;
  else case(idx)1:logo_color=9'b111_010_010;2:logo_color=9'b010_100_111;default:logo_color=0;endcase
 end endfunction
 always @(posedge clk or posedge rst)begin
  if(rst)begin xq<=0;rowq<=0;valid_q<=0;logo_top<=0;logo_bottom<=0;end
  else begin
   xq<=x;rowq<=row;valid_q<={valid_q[0],enable};
   logo_top<=logo_color(logo_data[1:0],xq,{1'b0,rowq});
   logo_bottom<=logo_color(logo_data[3:2],xq,{1'b1,rowq});
  end
 end
 function[3:0]bayer;input[1:0]px,py;begin
 case({py,px})
 0:bayer=0;1:bayer=8;2:bayer=2;3:bayer=10;4:bayer=12;5:bayer=4;6:bayer=14;7:bayer=6;
 8:bayer=3;9:bayer=11;10:bayer=1;11:bayer=9;12:bayer=15;13:bayer=7;14:bayer=13;default:bayer=5;
 endcase end endfunction
 function[3:0]halfheight;input[1:0]bar;input[2:0]level;begin
 if(bar==0)case(level)0:halfheight=0;1,2:halfheight=1;3,4:halfheight=2;5,6:halfheight=3;default:halfheight=4;endcase
 else if(bar==1)case(level)0:halfheight=0;1:halfheight=1;2:halfheight=2;3:halfheight=3;4:halfheight=5;5:halfheight=6;6:halfheight=7;default:halfheight=8;endcase
 else case(level)0:halfheight=0;1,2:halfheight=1;3:halfheight=2;4:halfheight=3;5,6:halfheight=4;default:halfheight=5;endcase
 end endfunction
 function[9:0]lookup;
 input[5:0]px,py;input[3:0]idx;input[15:0]fontbits;
 reg[5:0]xx,yy,ax,ay,nx,ny,dy;reg allowed,corner,wing;
 reg[3:0]rank,h,segcol;reg[1:0]bar,segment;
 reg[2:0]level,cgain;reg[2:0]kind;reg[6:0]metric;
 begin
  lookup=0;xx=0;yy=0;ax=0;ay=0;allowed=0;kind=render_state[`P_EFFECT];metric=render_state[`P_METRIC];
  nx=px<=7?px:63-px;ny=py<=38?py:76-py;rank=0;corner=0;wing=0;bar=0;level=0;h=0;dy=py>=38?py-38:38-py;
  segment=px[5:4];segcol=px[3:0]-1'b1;cgain=render_state[`P_CORNER_GAIN];
  if(py<16)begin if(fontbits[py[3:0]])lookup=575;end
  else if(py>=61)begin
   if(px[3:0]>=1&&px[3:0]<=14&&(py==62||(px[3:0]!=1&&px[3:0]!=14)))begin
    if(segment<render_state[`P_STAGE])lookup=10'd512+{5'd0,segment,3'd3};
    else if(segment==render_state[`P_STAGE]&&segcol<render_state[`P_FILL])begin
     if(render_state[`P_FILL]!=0&&segcol==render_state[`P_FILL]-1'b1)lookup=567;
     else lookup=10'd512+{5'd0,segment,3'd7};
    end else lookup=576;
   end
  end else if(px>=9&&px<=53)begin
   xx=px-9;yy=py-16;ax=xx>=22?xx-22:22-xx;ay=yy>=22?yy-22:22-yy;
   case(kind)
    0:allowed=(render_state[`P_DIR]?{1'b0,xx}:{1'b0,6'd44-xx})+{1'b0,yy}<=metric;
    1:allowed=ax<=metric;
    2:allowed={1'b0,ax}+{1'b0,ay}<=metric;
    3:allowed={3'd0,bayer(xx[1:0],yy[1:0])}<metric;
    4:allowed=1;
    5:allowed=ax<=metric&&ay<=metric;
    default:allowed=0;
   endcase
   if(allowed)lookup={1'b0,render_state[`P_BANK],render_state[`P_GAIN],idx};
  end else if(render_state[`P_DECOR])begin
   if(ny==22&&nx>=1&&nx<=7)begin corner=1;rank=7-nx;end
   else if(nx==1&&ny>=23&&ny<=27)begin corner=1;rank=ny-16;end
   if(corner&&rank<=render_state[`P_UNFOLD])begin
    if(render_state[`P_EMPHASIS]&&{1'b0,rank}+1>={1'b0,render_state[`P_FOCUS]}&&
       {1'b0,rank}<={1'b0,render_state[`P_FOCUS]}+1+render_state[`P_FRACTION])cgain=7;
    lookup=10'd512+{5'd0,render_state[`P_STAGE],cgain};
   end
   case(px)
    2:begin wing=1;bar=0;level=render_state[`P_V2];end
    4:begin wing=1;bar=1;level=render_state[`P_V0];end
    6:begin wing=1;bar=2;level=render_state[`P_V1];end
    61:begin wing=1;bar=0;level=render_state[`P_M2];end
    59:begin wing=1;bar=1;level=render_state[`P_M0];end
    57:begin wing=1;bar=2;level=render_state[`P_M1];end
   endcase
   h=halfheight(bar,level);
   if(wing&&dy<=h)begin
    cgain=level==0?2:level>=6?6:level>=3?5:4;
    lookup=px<8?10'd544+cgain:10'd552+cgain;
    if(dy==h&&level>=5)lookup=567;
   end
  end
 end endfunction
 wire[9:0]ta=lookup(xq,{1'b0,rowq},top_index,font_data);
 wire[9:0]ba=lookup(xq,{1'b1,rowq},bottom_index,16'd0);
 wire[8:0]tc,bc;
 panel_style_rom u_style(clk,1'b1,ta,tc,ba,bc);
 assign top_rgb=startup_mode?logo_top:tc;
 assign bottom_rgb=startup_mode?logo_bottom:bc;
 assign valid=valid_q[1];
endmodule
`endif
