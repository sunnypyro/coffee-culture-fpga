// F11 approved preview05. Scanner/boot preserved; explicit two-ROM pipeline.
`timescale 1ns/1ps
`include "assets/panel_contract.vh"
module hub75_scene_driver #(
 parameter DIV_W=2,parameter TBASE=12'd256,parameter SCROLL_DIV=24'd2000000)(
 input wire clk,rst,input wire[1:0]track_id,input wire track_start,pause,fast_mode,
 input wire startup_started,playback_ready,
 input wire voice_epoch,input wire[1:0]voice_track_q,input wire[18:0]voice_pos,
 input wire voice_active,input wire[21:0]music_pos,input wire music_active,snapshot_valid,
 output reg HUB_R1,HUB_G1,HUB_B1,HUB_R2,HUB_G2,HUB_B2,
 output reg[4:0]HUB_ADDR,output reg HUB_CLK,HUB_LAT,HUB_OE
);
    localparam ST_PREFETCH = 2'd3;
    localparam ST_SHIFT = 2'd0;
    localparam ST_LATCH = 2'd1;
    localparam ST_ON    = 2'd2;

    reg  [5:0]        col;
    reg  [4:0]        row;           // 行组 0..31
    reg  [1:0]        sf;            // 子场 2->1->0
    reg  [DIV_W-1:0]  div;
    reg  [1:0]        lat_cnt;
    reg  [11:0]       on_cnt;
    reg  [1:0]        st;

    wire [11:0] on_len = TBASE << sf;

    // F06: share the scanner and a single packed top/bottom Logo ROM.
    reg [1:0] boot_start_sync, ready_sync;
    reg startup_mode;
    reg [23:0] scroll_cnt; // shared by startup reveal and normal title scrolling
    reg [1:0] reveal_stage;
    reg [6:0] diagonal_limit, scan_diagonal_limit;
    reg [5:0] text_edge, scan_text_edge;
    wire scan_boundary = (st==ST_ON) && (on_cnt>=on_len) &&
                         (row==5'd31) && (sf==2'd0);
    wire startup_release = scan_boundary && startup_mode && ready_sync[1];
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            boot_start_sync<=0; ready_sync<=0; startup_mode<=1;
            reveal_stage<=0; diagonal_limit<=7'd20;
            text_edge<=6'd10; scan_diagonal_limit<=7'd19; scan_text_edge<=6'd10;
        end else begin
            boot_start_sync<={boot_start_sync[0],startup_started};
            ready_sync<={ready_sync[0],playback_ready};
            if (boot_start_sync[1] && startup_mode) begin
                if (reveal_stage==0) begin
                    if (scroll_cnt[19:0]==20'd779220) begin
                        diagonal_limit<=diagonal_limit+1'b1;
                        if (diagonal_limit==7'd96) reveal_stage<=1;
                    end
                end else if (reveal_stage==1) begin
                    if (scroll_cnt[19:0]==20'd914633) begin
                        text_edge<=text_edge+1'b1;
                        if (text_edge==6'd50) reveal_stage<=2;
                    end
                end
            end
            if (scan_boundary) begin
                if (boot_start_sync[1]) begin
                    scan_diagonal_limit<=diagonal_limit; scan_text_edge<=text_edge;
                end
                if (ready_sync[1]) startup_mode<=0;
            end
        end
    end
    wire [3:0] startup_indices;
    f06_sp_memory #(.WIDTH(4),.AW(11),.DEPTH(2048),.IMPLEMENT("9K"),
        .INIT_FILE("../../../td_project/startup_assets/startup_logo.mif")) u_startup_logo (
        .clk(clk),.ce(startup_mode),.we(1'b0),.addr({row,col}),.din(4'd0),.dout(startup_indices));
    function [8:0] startup_color;
        input [1:0] idx;
        input [5:0] px, py;
        reg [6:0] distance;
        begin
            distance={1'b0,~px}+{1'b0,py};
            if (idx==2'd3) startup_color=px<=scan_text_edge ? 9'h1ff : 9'd0;
            else if (distance>scan_diagonal_limit) startup_color=9'd0;
            else case (idx)
                2'd1: startup_color=9'b111_010_010;
                2'd2: startup_color=9'b010_100_111;
                default: startup_color=9'd0;
            endcase
        end
    endfunction


 reg[9:0]scroll,scan_scroll;
 always @(posedge clk or posedge rst)begin
  if(rst)begin scroll<=0;scroll_cnt<=0;scan_scroll<=0;end
  else begin
   if(startup_mode)begin
    scroll<=0;
    if(!boot_start_sync[1]||reveal_stage==2||
       (reveal_stage==0&&scroll_cnt[19:0]==779220)||
       (reveal_stage==1&&scroll_cnt[19:0]==914633))scroll_cnt<=0;
    else scroll_cnt<={4'd0,scroll_cnt[19:0]+20'd1};
   end else if(scroll_cnt>=SCROLL_DIV-1'b1)begin
    scroll_cnt<=0;scroll<=scroll==714?10'd0:scroll+1'b1;
   end else scroll_cnt<=scroll_cnt+1'b1;
   if(scan_boundary)scan_scroll<=scroll;
  end
 end
 function[10:0]mul45;input[5:0]v;reg[10:0]w;begin w={5'd0,v};mul45=(w<<5)+(w<<3)+(w<<2)+w;end endfunction
 wire inside_x=col>=9&&col<=53;
 wire[10:0]addr_top=inside_x&&row>=16?mul45({1'b0,row}-6'd16)+{5'd0,col-6'd9}:11'd0;
 wire[10:0]addr_bottom=inside_x&&row<=28?mul45({1'b0,row}+6'd16)+{5'd0,col-6'd9}:11'd0;
 wire[10:0]font_sum={1'b0,scan_scroll}+{5'd0,col};
 wire[9:0]font_addr=font_sum>=715?font_sum-11'd715:font_sum[9:0];
 wire[15:0]font_data;wire[3:0]top_index,bottom_index;
 wire request,busy,ready,commit_due,committed,decode_error,active_valid;
 wire[8:0]event_id,active_event;wire[7:0]epoch,active_epoch,target_tick,next_tick;wire[1:0]active_palette;
 wire[`PANEL_STATE_W-1:0]live_state;reg[`PANEL_STATE_W-1:0]scan_state;
 reg[`PANEL_STATE_W-1:0]renderer_state;
 hub75_timeline u_timeline(clk,rst,voice_epoch,voice_track_q,voice_pos,voice_active,music_pos,music_active,snapshot_valid,
  track_start,track_id,fast_mode,pause,startup_release,scan_boundary,busy,ready,active_event,target_tick,next_tick,committed,
  request,event_id,epoch,commit_due,live_state);
 hub75_frame_store_delta u_frame_store(
  .clk(clk),.rst(rst),.shift_enable(st==ST_SHIFT||st==ST_PREFETCH),.on_enable(st==ST_ON),
  .frame_request(request),.requested_frame(event_id),.request_epoch(epoch),.current_epoch(epoch),
  .commit_due(commit_due),.commit_boundary(scan_boundary),.pause(pause),
  .scan_top_addr(addr_top),.scan_bottom_addr(addr_bottom),.top_pixel(top_index),.bottom_pixel(bottom_index),
  .active_frame(active_event),.active_epoch(active_epoch),.active_bank_id(active_palette),.target_tick(target_tick),.next_tick(next_tick),
  .busy(busy),.load_ready(ready),.commit_pulse(committed),.error(decode_error),.active_valid(active_valid));
 panel_font_rom u_font_rom(clk,font_addr,font_data);
 always @(posedge clk or posedge rst)begin
  if(rst)scan_state<=0;
  else if(scan_boundary&&!pause&&(active_epoch==epoch||(ready&&commit_due)))scan_state<=live_state;
 end
 always @*begin renderer_state=scan_state;renderer_state[`P_BANK]=active_palette;end
 wire[8:0]rgb_top,rgb_bottom;wire pixel_valid;
 hub75_renderer u_renderer(clk,rst,st==ST_SHIFT||st==ST_PREFETCH,col,row,top_index,bottom_index,font_data,
  renderer_state,startup_mode,startup_indices,scan_diagonal_limit,scan_text_edge,rgb_top,rgb_bottom,pixel_valid);
 wire visible=pixel_valid&&(startup_mode?boot_start_sync[1]:active_valid);
 wire[3:0]ri=6+{2'd0,sf},gi=3+{2'd0,sf},bi={2'd0,sf};
 // Four cycles/pixel: source read, palette read, registered pins, CLK rise.
 // A four-cycle row prefetch also flushes reset/bank/row changes before CLK.
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   col<=0;row<=0;sf<=2;div<=0;lat_cnt<=0;on_cnt<=0;st<=ST_PREFETCH;
   HUB_R1<=0;HUB_G1<=0;HUB_B1<=0;HUB_R2<=0;HUB_G2<=0;HUB_B2<=0;
   HUB_ADDR<=0;HUB_CLK<=0;HUB_LAT<=0;HUB_OE<=1;
  end else case(st)
   ST_PREFETCH:begin
    HUB_OE<=1;HUB_LAT<=0;HUB_CLK<=0;HUB_ADDR<=row;div<=div+1'b1;
    if(div=={DIV_W{1'b1}})begin st<=ST_SHIFT;div<=0;end
   end
   ST_SHIFT:begin
    HUB_OE<=1;HUB_LAT<=0;HUB_ADDR<=row;HUB_CLK<=div=={DIV_W{1'b1}};
    if(div==({DIV_W{1'b1}}-1'b1))begin
     HUB_R1<=visible&&rgb_top[ri];HUB_G1<=visible&&rgb_top[gi];HUB_B1<=visible&&rgb_top[bi];
     HUB_R2<=visible&&rgb_bottom[ri];HUB_G2<=visible&&rgb_bottom[gi];HUB_B2<=visible&&rgb_bottom[bi];
    end
    div<=div+1'b1;
    if(div=={DIV_W{1'b1}})begin if(col==63)st<=ST_LATCH;else col<=col+1'b1;end
   end
   ST_LATCH:begin
    HUB_CLK<=0;HUB_LAT<=1;lat_cnt<=lat_cnt+1'b1;
    if(lat_cnt==2)begin lat_cnt<=0;HUB_LAT<=0;on_cnt<=0;st<=ST_ON;end
   end
   ST_ON:begin
    HUB_OE<=0;on_cnt<=on_cnt+1'b1;
    if(on_cnt>=on_len)begin
     HUB_OE<=1;col<=0;div<=0;
     if(row==31)begin row<=0;sf<=sf==0?2:sf-1'b1;end else row<=row+1'b1;
     st<=ST_PREFETCH;
    end
   end
   default:st<=ST_PREFETCH;
  endcase
 end
endmodule
