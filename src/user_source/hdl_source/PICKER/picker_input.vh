`ifndef FOUR_GRID_PICKER_INPUT
`define FOUR_GRID_PICKER_INPUT
// SW1 and picker keys use stable-vector debounce.  The KEY1 ownership latch
// deliberately survives a playback soft reset until the physical key is up.
module picker_input #(
 parameter integer DEBOUNCE_CYCLES=1000000,
 parameter integer LONG_CYCLES=100000000
)(
 input wire clk,power_rst,soft_reset_active,sw1,
 input wire[3:0]key_n,
 input wire menu_select_enabled,menu_closed_ack,cmd_ready,
 output reg cmd_valid,output reg[2:0]cmd_kind,output reg[1:0]cmd_idx,
 output reg input_owned,output wire key1_reset_req,
 output wire[2:0]normal_keys_n
);
 localparam integer DW=(DEBOUNCE_CYCLES<2)?1:$clog2(DEBOUNCE_CYCLES);
 localparam integer LW=(LONG_CYCLES<2)?1:$clog2(LONG_CYCLES+1);
 (* syn_preserve=1 *) reg[1:0]sw_sync;
 (* syn_preserve=1 *) reg[3:0]key_sync0,key_sync1;
 reg sw_candidate,sw_level,sw_initialized,sw_changed;
 reg[3:0]key_candidate,key_level;
 reg keys_changed;
 reg[DW-1:0]sw_count,key_count;
 reg desired_open,sent_open,closed_seen,armed,key1_short,long_reset;
 reg[LW-1:0]long_count;
 wire[3:0]pressed=~key_level;
 assign key1_reset_req=(!key_n[0]&&!input_owned)||long_reset;
 assign normal_keys_n=input_owned?3'b111:key_n[3:1];

 always @(posedge clk or posedge power_rst)begin
  if(power_rst)begin
   sw_sync<=0;key_sync0<=15;key_sync1<=15;sw_candidate<=0;
   sw_level<=0;sw_initialized<=0;sw_changed<=0;sw_count<=0;
   key_candidate<=15;key_level<=15;keys_changed<=0;key_count<=0;
  end else begin
   sw_sync<={sw_sync[0],sw1};key_sync0<=key_n;key_sync1<=key_sync0;
   sw_changed<=0;keys_changed<=0;
   if(sw_sync[1]!=sw_candidate)begin sw_candidate<=sw_sync[1];sw_count<=0;end
   else if(sw_count<DEBOUNCE_CYCLES-1)sw_count<=sw_count+1'b1;
   else if(!sw_initialized)begin sw_initialized<=1;sw_level<=sw_candidate;end
   else if(sw_level!=sw_candidate)begin sw_level<=sw_candidate;sw_changed<=1;end
   if(key_sync1!=key_candidate)begin key_candidate<=key_sync1;key_count<=0;end
   else if(key_count<DEBOUNCE_CYCLES-1)key_count<=key_count+1'b1;
   else if(key_level!=key_candidate)begin key_level<=key_candidate;keys_changed<=1;end
  end
 end

 always @(posedge clk or posedge power_rst)begin
  if(power_rst)begin
   cmd_valid<=0;cmd_kind<=0;cmd_idx<=0;input_owned<=0;
   desired_open<=0;sent_open<=0;closed_seen<=1;armed<=0;
   key1_short<=0;long_count<=0;long_reset<=0;
  end else begin
   if(cmd_valid&&cmd_ready)cmd_valid<=0;
   if(!key_level[0]&&input_owned)begin
    if(long_count<LONG_CYCLES)long_count<=long_count+1'b1;
    if(long_count>=LONG_CYCLES-1)begin long_reset<=1;key1_short<=0;end
   end else begin long_count<=0;long_reset<=0;end
   if(soft_reset_active)begin
    cmd_valid<=0;desired_open<=0;sent_open<=0;closed_seen<=1;
    armed<=0;key1_short<=0;
   end else begin
    if(menu_closed_ack)begin
     desired_open<=0;sent_open<=0;closed_seen<=1;armed<=0;key1_short<=0;
    end
    if(closed_seen&&key_level==15&&key_sync1==15&&key_candidate==15&&
       key_count>=DEBOUNCE_CYCLES-1&&!desired_open&&!cmd_valid)
     input_owned<=0;
    if(!menu_select_enabled)begin armed<=0;key1_short<=0;end
    else if(input_owned&&key_level==15&&!key1_short)armed<=1;

    if(sw_changed)begin
     // A locked selection can complete and reopen GRID after a late cancel.
     // The visible/selectable grid is authoritative for the next SW action.
     desired_open<=menu_closed_ack?1'b1:(menu_select_enabled?1'b0:~desired_open);
     if(menu_select_enabled&&!menu_closed_ack)sent_open<=1'b1;
     input_owned<=1;closed_seen<=0;armed<=0;key1_short<=0;
    end else if(!cmd_valid&&desired_open!=sent_open)begin
     cmd_valid<=1;cmd_kind<=desired_open?3'd1:3'd2;cmd_idx<=0;
     sent_open<=desired_open;
    end else if(keys_changed&&input_owned&&menu_select_enabled&&
                desired_open==sent_open&&!cmd_valid&&!long_reset)begin
     if(pressed==0&&key1_short)begin
      cmd_valid<=1;cmd_kind<=3;cmd_idx<=3;key1_short<=0;armed<=0;
     end else if(armed)begin
      case(pressed)
       4'b1000:begin cmd_valid<=1;cmd_kind<=3;cmd_idx<=0;armed<=0;end
       4'b0100:begin cmd_valid<=1;cmd_kind<=3;cmd_idx<=1;armed<=0;end
       4'b0010:begin cmd_valid<=1;cmd_kind<=3;cmd_idx<=2;armed<=0;end
       4'b0001:begin key1_short<=1;armed<=0;end
       4'b0000:begin end
       default:begin armed<=0;key1_short<=0;end
      endcase
     end
    end
   end
  end
 end
endmodule
`endif
