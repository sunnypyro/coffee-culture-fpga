`timescale 1ns/1ps
`ifndef F11_FRAME_STORE
`define F11_FRAME_STORE
module hub75_frame_store_delta(
 input wire clk,rst,shift_enable,on_enable,frame_request,
 input wire[8:0]requested_frame,input wire[7:0]request_epoch,current_epoch,
 input wire commit_due,commit_boundary,pause,input wire[10:0]scan_top_addr,scan_bottom_addr,
 output wire[3:0]top_pixel,bottom_pixel,output reg[8:0]active_frame,
 output reg[7:0]active_epoch,output reg[1:0]active_bank_id,
 output reg[7:0]target_tick,next_tick,output wire busy,load_ready,output reg commit_pulse,error,active_valid
);
 localparam IDLE=0,DIR_REQ=1,DIR_USE=2,VALIDATE=3,COPY_REQ=4,COPY_CAP=5,
 COPY_WRITE=6,CLEAR=7,BYTE_REQ=8,BYTE_USE=9,COMMAND=10,FIRST=11,TAIL=12,
 PIXEL=13,RUN_LENGTH=14,RUN_WRITE=15,LITERAL_FETCH=16,LITERAL_LOW=17,
 LITERAL_HIGH=18,RAW_FETCH=19,RAW_LOW=20,RAW_HIGH=21,READY=22,NEXT_REQ=23,NEXT_USE=24,META_SETTLE=25;
 reg[4:0]state,continuation;
 reg active_bank,extend_hidden;
 reg[8:0]target;
 reg[7:0]epoch,flags;
 reg[2:0]dir_index;
 reg[15:0]offset,size;
 reg[14:0]payload_index;
 reg[11:0]cursor,pixel_address;
 reg[8:0]remaining;
 reg[7:0]byte_value,first;
 reg[3:0]pixel_value,copy_value;
 wire[3:0]b0a,b0b,b1a,b1b;
 wire permit=on_enable&&!shift_enable&&!frame_request;
 wire copy_read=permit&&state==COPY_REQ;
 wire writing=permit&&(state==COPY_WRITE||state==CLEAR||state==PIXEL||state==RUN_WRITE||
                         state==LITERAL_LOW||state==LITERAL_HIGH||state==RAW_LOW||state==RAW_HIGH);
 wire[11:0]write_addr=state==PIXEL?pixel_address:cursor;
 wire[3:0]write_value=state==CLEAR?4'd0:state==COPY_WRITE?copy_value:
    (state==RAW_LOW||state==LITERAL_LOW)?byte_value[3:0]:
    (state==RAW_HIGH||state==LITERAL_HIGH)?byte_value[7:4]:pixel_value;
 wire safe_write=writing&&write_addr<2025;
 wire[10:0]a0=shift_enable&&!active_bank?scan_top_addr:cursor[10:0];
 wire[10:0]a1=shift_enable&&active_bank?scan_top_addr:cursor[10:0];
 hub75_frame_buffer_dp #(.INIT_FILE("assets/panel_frame_init.mif")) u_buffer0(
 clk,a0,(!active_bank&&(shift_enable||copy_read)),b0a,
 shift_enable&&!active_bank?scan_bottom_addr:write_addr[10:0],
 (!active_bank&&shift_enable)||(active_bank&&safe_write),active_bank&&safe_write,write_value,b0b);
 hub75_frame_buffer_dp #(.INIT_FILE("assets/panel_frame_init.mif")) u_buffer1(
 clk,a1,(active_bank&&(shift_enable||copy_read)),b1a,
 shift_enable&&active_bank?scan_bottom_addr:write_addr[10:0],
 (active_bank&&shift_enable)||(!active_bank&&safe_write),!active_bank&&safe_write,write_value,b1b);
 assign top_pixel=active_bank?b1a:b0a;
 assign bottom_pixel=active_bank?b1b:b0b;
 assign busy=state!=IDLE;
 assign load_ready=state==READY;
 wire[16:0]dir_addr=({8'd0,target}<<2)+({8'd0,target}<<1)+dir_index;
 wire[16:0]payload_addr={1'b0,offset}+{2'b0,payload_index};
 wire[16:0]next_dir_addr=({8'd0,target}<<2)+({8'd0,target}<<1)+17'd11;
 wire rom_ce=permit&&(state==DIR_REQ||state==BYTE_REQ||state==NEXT_REQ);
 wire[14:0]rom_addr=state==DIR_REQ?dir_addr[14:0]:state==NEXT_REQ?next_dir_addr[14:0]:payload_addr[14:0];
 wire[7:0]rom_data;
 panel_img_delta_rom u_delta_rom(clk,rom_ce,rom_addr,rom_data);
 wire[11:0]absolute_addr={1'b0,byte_value[3:0],first[6:0]};
 task fail;
 begin error<=1;state<=IDLE;end
 endtask
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   state<=IDLE;continuation<=0;active_bank<=0;active_valid<=0;active_frame<=0;
   active_epoch<=0;active_bank_id<=0;target_tick<=0;next_tick<=255;extend_hidden<=0;target<=0;epoch<=0;flags<=0;
   dir_index<=0;offset<=0;size<=0;payload_index<=0;cursor<=0;pixel_address<=0;
   remaining<=0;byte_value<=0;first<=0;pixel_value<=0;copy_value<=0;error<=0;commit_pulse<=0;
  end else begin
   commit_pulse<=0;
   if(frame_request)begin
    extend_hidden<=state==READY&&request_epoch==epoch&&requested_frame==target+9'd1;
    target<=requested_frame;epoch<=request_epoch;dir_index<=0;payload_index<=0;
    cursor<=0;offset<=0;size<=0;error<=0;
    if(requested_frame>=415)begin state<=IDLE;error<=1;end else state<=DIR_REQ;
   end else if(commit_boundary&&commit_due&&!pause&&epoch==current_epoch&&state==READY)begin
    active_bank<=~active_bank;active_frame<=target;active_epoch<=epoch;
    active_bank_id<=flags[5:4];active_valid<=1;commit_pulse<=1;state<=IDLE;
   end else if(state==COPY_CAP)begin
    // Capture the copy response even if scanner ownership changed this edge.
    copy_value<=top_pixel;state<=COPY_WRITE;
   end else if(permit)begin
    case(state)
     IDLE:;
     DIR_REQ:state<=DIR_USE;
     DIR_USE:begin
      case(dir_index)
       0:offset[7:0]<=rom_data;1:offset[15:8]<=rom_data;
       2:size[7:0]<=rom_data;3:size[15:8]<=rom_data;
       4:flags<=rom_data;5:target_tick<=rom_data;
      endcase
      if(dir_index==5)state<=VALIDATE;
      else begin dir_index<=dir_index+1'b1;state<=DIR_REQ;end
     end
     VALIDATE:begin
      if(offset<2490||({1'b0,offset}+{1'b0,size})>24576||flags[1:0]==3)fail;
      else if(flags[1:0]==1)begin if(size!=1013)fail;else state<=RAW_FETCH;end
      else if(flags[1:0]==2)state<=CLEAR;
      else if(extend_hidden)state<=COMMAND;
      else if(!active_valid)fail;
      else state<=COPY_REQ;
     end
     COPY_REQ:state<=COPY_CAP;
     COPY_WRITE:begin
      if(cursor==2024)begin cursor<=0;state<=COMMAND;end
      else begin cursor<=cursor+1'b1;state<=COPY_REQ;end
     end
     CLEAR:begin
      if(cursor==2024)begin cursor<=0;state<=COMMAND;end
      else cursor<=cursor+1'b1;
     end
     COMMAND:begin
      if(payload_index==size)state<=NEXT_REQ;
      else begin continuation<=FIRST;state<=BYTE_REQ;end
     end
     BYTE_REQ:begin
      if(payload_index>=size||payload_addr>=24576)fail;else state<=BYTE_USE;
     end
     BYTE_USE:begin byte_value<=rom_data;payload_index<=payload_index+1'b1;state<=continuation;end
     FIRST:begin
      if(!byte_value[7])begin
       pixel_address<=cursor+{9'd0,byte_value[6:4]};pixel_value<=byte_value[3:0];state<=PIXEL;
      end else begin first<=byte_value;continuation<=TAIL;state<=BYTE_REQ;end
     end
     TAIL:begin
      if(absolute_addr<2025)begin pixel_address<=absolute_addr;pixel_value<=byte_value[7:4];state<=PIXEL;end
      else if(absolute_addr==2047)begin pixel_value<=byte_value[7:4];continuation<=RUN_LENGTH;state<=BYTE_REQ;end
      else if(absolute_addr==2045)begin
       if(cursor+{8'd0,byte_value[7:4]}+2>2025)fail;
       else begin remaining<={5'd0,byte_value[7:4]}+2;state<=LITERAL_FETCH;end
      end else fail;
     end
     PIXEL:begin
      if(pixel_address>=2025)fail;
      else begin cursor<=pixel_address+1'b1;state<=COMMAND;end
     end
     RUN_LENGTH:begin
      if(cursor+{4'd0,byte_value}+2>2025)fail;
      else begin remaining<={1'b0,byte_value}+9'd2;state<=RUN_WRITE;end
     end
     RUN_WRITE:begin
      cursor<=cursor+1'b1;remaining<=remaining-1'b1;
      if(remaining==1)state<=COMMAND;
     end
     LITERAL_FETCH:begin continuation<=LITERAL_LOW;state<=BYTE_REQ;end
     LITERAL_LOW:begin
      cursor<=cursor+1'b1;remaining<=remaining-1'b1;
      if(remaining==1)state<=COMMAND;else state<=LITERAL_HIGH;
     end
     LITERAL_HIGH:begin
      cursor<=cursor+1'b1;remaining<=remaining-1'b1;
      if(remaining==1)state<=COMMAND;else state<=LITERAL_FETCH;
     end
     RAW_FETCH:begin continuation<=RAW_LOW;state<=BYTE_REQ;end
     RAW_LOW:begin
      if(cursor==2024)begin
       if(byte_value[7:4]!=0)fail;else state<=NEXT_REQ;
      end else begin cursor<=cursor+1'b1;state<=RAW_HIGH;end
     end
     RAW_HIGH:begin cursor<=cursor+1'b1;state<=RAW_FETCH;end
     NEXT_REQ:begin
      if(target>=414)begin next_tick<=255;state<=META_SETTLE;end else state<=NEXT_USE;
     end
     NEXT_USE:begin next_tick<=rom_data;state<=META_SETTLE;end
     META_SETTLE:state<=READY;
     READY:;
     default:fail;
    endcase
   end
  end
 end
endmodule
`endif

module hub75_frame_buffer_dp #(
    parameter INIT_FILE = "NONE"
) (
    input  wire        clk,
    input  wire [10:0] addra,
    input  wire        cea,
    output wire [3:0]  douta,
    input  wire [10:0] addrb,
    input  wire        ceb,
    input  wire        web,
    input  wire [3:0]  dinb,
    output wire [3:0]  doutb
);
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A (4),
        .ADDR_WIDTH_A (11),
        .DATA_DEPTH_A (2048),
        .DATA_WIDTH_B (4),
        .ADDR_WIDTH_B (11),
        .DATA_DEPTH_B (2048),
        .MODE         ("DP"),
        .REGMODE_A    ("NOREG"),
        .REGMODE_B    ("NOREG"),
        .IMPLEMENT    ("9K"),
        .DEBUGGABLE   ("NO"),
        .PACKABLE     ("NO"),
        .INIT_FILE    (INIT_FILE),
        .FILL_ALL     ("NONE")
    ) inst (
        .dia  (4'd0),
        .dib  (dinb),
        .addra(addra),
        .addrb(addrb),
        .cea  (cea),
        .ceb  (ceb),
        .ocea (1'b0),
        .oceb (1'b0),
        .clka (clk),
        .clkb (clk),
        .wea  (1'b0),
        .web  (web),
        .bea  (1'b0),
        .beb  (1'b1),
        .rsta (1'b0),
        .rstb (1'b0),
        .doa  (douta),
        .dob  (doutb)
    );
endmodule
