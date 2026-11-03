`ifndef FOUR_GRID_PICKER_CONTROL
`define FOUR_GRID_PICKER_CONTROL
module picker_control #(
 parameter integer CLK_HZ=100000000
)(
 input wire clk,rst,cmd_valid,input wire[2:0]cmd_kind,input wire[1:0]cmd_idx,
 input wire display_ready,normal_idle,normal_urgent,normal_visible,transition_wait,voice_hold_applied,
 input wire raw_idle,raw_data_start,raw_failed,raw_write_done,raw_progress,audio_need,
 input wire full_done,abort_ack,abort_released,
 input wire[1:0]current_buf,current_idx,input wire[3:0]photo_mask,
 input wire cache0_valid,cache1_valid,input wire[1:0]cache0_idx,cache1_idx,
 input wire view_ready,view_result_valid,input wire[7:0]view_result_id,
 input wire[1:0]view_result_code,
 output wire menu_active,body_hold,select_enabled,entry_quiesce,
 output reg thumb_active,thumb_start,output reg[1:0]thumb_idx,
 output reg full_start,output reg[1:0]full_idx,full_buf,
 output reg abort_req,abort_normal_done,
 output reg view_send,view_cancel,output reg[7:0]view_id,output reg[1:0]view_source,
 output reg selected_commit,output reg[1:0]selected_idx,selected_buf,
 output reg closed_event,output wire feedback_wait,output wire selecting,
 output wire[3:0]tile_valid_mask
);
 localparam S_NORMAL=0,S_ENTER=1,S_BUILD=2,S_GREQ=3,S_GWAIT=4,S_GRID=5,
 S_FLOAD=6,S_FWAIT=7,S_RREQ=8,S_RWAIT=9,S_REOPEN=10,S_CLOSE=11,S_RECOVER=12;
 reg[3:0]state;
 reg[2:0]build_state;
 reg[3:0]tiles,failed;
 reg b_seen,b_source_done,b_write_done,b_bad;
 reg[2:0]quiet_count;
 reg cancel_pending,cancel_sent,reopen_pending;
 reg releasing,abort_was_normal,aborted;
 reg full_seen;
 reg[1:0]return_buf,return_idx;
 reg[1:0]reopen_count;
 localparam integer TW=$clog2(CLK_HZ/1000);
 reg[TW-1:0]ms_count;reg[6:0]feedback_ms;
 reg[11:0]stale_ms;reg[13:0]job_ms;
 wire job_timeout=stale_ms>=3000||job_ms>=10000;
 wire ms_tick=ms_count==CLK_HZ/1000-1;
 assign menu_active=state!=S_NORMAL;
 assign body_hold=state!=S_NORMAL&&state!=S_ENTER;
 assign entry_quiesce=state==S_ENTER;
 assign select_enabled=state==S_GRID&&!cancel_pending&&!abort_req&&!releasing;
 assign feedback_wait=feedback_ms>=100;
 assign selecting=state==S_FLOAD||state==S_FWAIT;
 assign tile_valid_mask=tiles;
 function[1:0]first_missing;input[3:0]mask;begin
  if(!mask[0])first_missing=0;else if(!mask[1])first_missing=1;
  else if(!mask[2])first_missing=2;else first_missing=3;
 end endfunction
 wire[3:0]blocked_tiles=tiles|failed|~photo_mask;
 wire[1:0]missing=first_missing(blocked_tiles);
 wire can_build=display_ready&&raw_idle&&normal_idle&&!normal_urgent&&!abort_req&&!releasing;
 wire build_allowed=state==S_NORMAL||state==S_ENTER||state==S_BUILD;
 wire can_start_build=build_allowed&&can_build&&(blocked_tiles!=4'hF);

 always @(posedge clk or posedge rst)begin
  if(rst)begin
   state<=S_NORMAL;build_state<=0;tiles<=0;failed<=0;b_seen<=0;b_source_done<=0;b_write_done<=0;b_bad<=0;quiet_count<=0;
   thumb_active<=0;thumb_start<=0;thumb_idx<=0;full_start<=0;full_idx<=0;full_buf<=0;full_seen<=0;
   abort_req<=0;abort_normal_done<=0;releasing<=0;abort_was_normal<=0;aborted<=0;
   view_send<=0;view_cancel<=0;view_id<=0;view_source<=0;
   selected_commit<=0;selected_idx<=0;selected_buf<=0;closed_event<=0;
   cancel_pending<=0;cancel_sent<=0;reopen_pending<=0;return_buf<=0;return_idx<=0;reopen_count<=0;
   ms_count<=0;feedback_ms<=0;stale_ms<=0;job_ms<=0;
  end else begin
   thumb_start<=0;full_start<=0;selected_commit<=0;closed_event<=0;view_send<=0;
   abort_normal_done<=0;aborted<=0;
   if(ms_tick)ms_count<=0;else ms_count<=ms_count+1'b1;
   if(build_state!=1&&state!=S_FLOAD)begin stale_ms<=0;job_ms<=0;end
   else if(raw_progress)stale_ms<=0;
   else if(ms_tick&&!audio_need)begin
    if(stale_ms<3000)stale_ms<=stale_ms+1'b1;
   end
   if(ms_tick&&!audio_need&&(build_state==1||state==S_FLOAD)&&job_ms<10000)
    job_ms<=job_ms+1'b1;
   if(ms_tick&&(state==S_BUILD||state==S_FLOAD||state==S_FWAIT)&&feedback_ms<100)
    feedback_ms<=feedback_ms+1'b1;
   if(abort_req&&abort_ack)begin abort_req<=0;releasing<=1;end
   if(releasing&&abort_released&&raw_idle)begin
    releasing<=0;aborted<=1;
    if(abort_was_normal)abort_normal_done<=1;
   end
   // A completed normal prefetch owns its BUF, not the physical decoder.
   case(build_state)
    0:if(can_start_build)begin
      thumb_idx<=missing;thumb_active<=1;thumb_start<=1;build_state<=1;
      b_seen<=0;b_source_done<=0;b_write_done<=0;b_bad<=0;quiet_count<=0;
     end
    1:begin
      if(raw_data_start)b_seen<=1;
      if(b_seen&&raw_idle)b_source_done<=1;
      if((b_seen||raw_data_start)&&raw_write_done)b_write_done<=1;
      if(raw_failed||job_timeout)begin b_bad<=1;abort_req<=1;abort_was_normal<=0;build_state<=3;end
      else if((normal_urgent&&state==S_NORMAL)||cancel_pending)begin
       abort_req<=1;abort_was_normal<=0;build_state<=3;
      end else if(b_source_done&&b_write_done)begin quiet_count<=0;build_state<=2;end
     end
    2:if(quiet_count==4)begin tiles[thumb_idx]<=1;thumb_active<=0;build_state<=0;end
      else quiet_count<=quiet_count+1'b1;
    3:if(aborted)begin
      if(b_bad)failed[thumb_idx]<=1;
      thumb_active<=0;build_state<=0;
     end
    default:build_state<=0;
   endcase

   if(cmd_valid)begin
    if(cmd_kind==1)begin
     if(state==S_NORMAL)begin state<=S_ENTER;return_buf<=current_buf;return_idx<=current_idx;cancel_pending<=0;reopen_pending<=0;failed<=0;feedback_ms<=0;end
     else if(state==S_RREQ||state==S_RWAIT||state==S_CLOSE)reopen_pending<=1;
    end else if(cmd_kind==2&&state!=S_NORMAL)cancel_pending<=1;
    else if(cmd_kind==3&&select_enabled)begin
     selected_idx<=cmd_idx;full_idx<=cmd_idx;full_seen<=0;feedback_ms<=0;
     if(cache0_valid&&cache0_idx==cmd_idx)begin selected_buf<=0;state<=S_FWAIT;end
     else if(cache1_valid&&cache1_idx==cmd_idx)begin selected_buf<=1;state<=S_FWAIT;end
     else begin
      full_buf<=current_buf^2'd1;selected_buf<=current_buf^2'd1;
      full_start<=1;state<=S_FLOAD;
     end
     cancel_sent<=0;
    end
   end
   case(state)
    S_NORMAL:begin cancel_pending<=0;end
    S_ENTER:begin
     if(cancel_pending&&!transition_wait&&!abort_req&&!releasing)begin
      state<=S_NORMAL;closed_event<=1;cancel_pending<=0;
     end
     else if(display_ready)begin
      if(!thumb_active&&!raw_idle&&!transition_wait&&!abort_req&&!releasing)begin
       abort_req<=1;abort_was_normal<=1;
      end
      if(normal_visible&&!transition_wait&&!abort_req&&!releasing&&
         (raw_idle||thumb_active))begin
       return_buf<=current_buf;return_idx<=current_idx;state<=S_BUILD;
      end
     end
    end
    S_BUILD:begin
     if(cancel_pending||photo_mask!=15||failed!=0)begin
      if(thumb_active&&build_state!=3)begin abort_req<=1;abort_was_normal<=0;build_state<=3;end
      state<=S_RREQ;
     end else if(tiles==15&&!thumb_active&&voice_hold_applied)state<=S_GREQ;
    end
    S_GREQ:if(view_ready)begin
      view_send<=1;view_cancel<=0;view_source<=2;view_id<=view_id+1'b1;
      cancel_sent<=0;state<=S_GWAIT;
     end
    S_GWAIT:begin
     if(cancel_pending&&!cancel_sent&&view_ready)begin view_send<=1;view_cancel<=1;cancel_sent<=1;end
     if(view_result_valid&&view_result_id==view_id)begin
      if(cancel_pending||view_result_code!=0)state<=S_RREQ;else state<=S_GRID;
     end
    end
    S_GRID:if(cancel_pending)state<=S_RREQ;
    S_FLOAD:begin
     if(raw_data_start&&!thumb_active)full_seen<=1;
     if(cancel_pending||raw_failed||job_timeout)begin
      abort_req<=1;abort_was_normal<=1;state<=S_RECOVER;
     end else if(full_seen&&full_done)state<=S_FWAIT;
    end
    S_FWAIT:begin
     // Before the first view command, cancel can return without a new commit.
     if(!cancel_sent)begin
      if(cancel_pending)state<=S_RREQ;
      else if(view_ready)begin
       view_send<=1;view_cancel<=0;view_source<=selected_buf;view_id<=view_id+1'b1;cancel_sent<=1;
      end
     end else begin
      if(cancel_pending&&view_ready&&!view_cancel)begin view_send<=1;view_cancel<=1;end
      if(view_result_valid&&view_result_id==view_id)begin
       if(view_result_code==0)begin
        selected_commit<=1;return_buf<=selected_buf;return_idx<=selected_idx;
        if(cancel_pending)begin state<=S_REOPEN;reopen_count<=0;end else state<=S_CLOSE;
       end else state<=S_RREQ;
      end
     end
    end
    S_RECOVER:if(aborted)begin if(cancel_pending)state<=S_RREQ;else state<=S_GRID;end
    S_RREQ:begin
     if(thumb_active&&build_state!=3)begin abort_req<=1;abort_was_normal<=0;build_state<=3;end
     if(view_ready)begin
      view_send<=1;view_cancel<=0;view_source<=return_buf;view_id<=view_id+1'b1;state<=S_RWAIT;
     end
    end
    S_RWAIT:if(view_result_valid&&view_result_id==view_id)state<=S_CLOSE;
    S_REOPEN:begin
     if(reopen_count==3)begin cancel_pending<=0;cancel_sent<=0;feedback_ms<=0;state<=S_BUILD;end
     else reopen_count<=reopen_count+1'b1;
    end
    S_CLOSE:if(!abort_req&&!releasing&&!thumb_active)begin
      if(reopen_pending)begin state<=S_ENTER;cancel_pending<=0;reopen_pending<=0;feedback_ms<=0;end
      else begin state<=S_NORMAL;closed_event<=1;cancel_pending<=0;end
     end
    default:state<=S_NORMAL;
   endcase
  end
 end
endmodule
`endif
