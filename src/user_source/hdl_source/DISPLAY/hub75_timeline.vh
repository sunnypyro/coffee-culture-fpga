`ifndef F11_TIMELINE
`define F11_TIMELINE
`include "assets/panel_contract.vh"
// Constant-rate virtual samples are used only by fast mode and terminal steam.
// Ordinary narration always follows the observer's absolute consumed position.
module hub75_timeline(
 input wire clk,rst,voice_epoch,input wire[1:0]voice_track_q,input wire[18:0]voice_pos,
 input wire voice_active,input wire[21:0]music_pos,input wire music_active,snapshot_valid,
 input wire track_commit,input wire[1:0]track_id,input wire fast_mode,pause,startup_release,scan_boundary,
 input wire busy,load_ready,input wire[8:0]active_event,input wire[7:0]target_tick,next_tick,
 input wire commit_pulse,output reg request,output reg[8:0]event_id,output reg[7:0]epoch,
 output wire commit_due,output reg[`PANEL_STATE_W-1:0]render_state
);
 reg[1:0]stage;reg seen_voice,fast_q,running,issued,tail_mode,tail_wrapped;
 reg[18:0]fast_pos;reg[16:0]steam_pos;
 reg[10:0]sample_div;reg[1:0]sample_phase;
 wire virtual_step=sample_div==(sample_phase==2?11'd1040:11'd1041);
 function[18:0]duration;input[1:0]s;begin case(s)
 0:duration=`P_SAMPLES_0;1:duration=`P_SAMPLES_1;2:duration=`P_SAMPLES_2;default:duration=`P_SAMPLES_3;endcase end endfunction
 function[8:0]first_event;input[1:0]s;begin case(s)
 0:first_event=`P_FIRST_0;1:first_event=`P_FIRST_1;2:first_event=`P_FIRST_2;default:first_event=`P_FIRST_3;endcase end endfunction
 function[8:0]last_event;input[1:0]s;begin case(s)
 0:last_event=`P_LAST_0;1:last_event=`P_LAST_1;2:last_event=`P_LAST_2;default:last_event=`P_LAST_3;endcase end endfunction
 wire voice_restart=!fast_mode&&voice_epoch!=seen_voice&&voice_track_q==stage;
 wire restart=track_commit||startup_release||fast_q!=fast_mode||voice_restart;
 wire[1:0]restart_stage=(track_commit||startup_release)?track_id:stage;
 wire[18:0]position=fast_mode?fast_pos:running&&voice_track_q==stage?voice_pos:19'd0;
 wire[18:0]bounded_pos=position>duration(stage)?duration(stage):position;
 wire ending=stage==3&&bounded_pos>=duration(stage);
 wire[18:0]event_sample=({11'd0,target_tick}<<11)-({11'd0,target_tick}<<7);
 reg due_q,skip_q;
 wire[18:0]next_event_sample=({11'd0,next_tick}<<11)-({11'd0,next_tick}<<7);
 // Route-driven timing cut: keep the wide source-position comparison out of
 // the frame-store state/scan-snapshot enables. Cancellation remains immediate.
 always @(posedge clk or posedge rst)begin
  if(rst)begin due_q<=0;skip_q<=0;end
  else if(restart||request)begin due_q<=0;skip_q<=0;end
  else begin
   due_q<=tail_mode?(tail_wrapped||(target_tick!=58&&{2'd0,steam_pos}>=event_sample)):
    ((event_id==first_event(stage))||(fast_mode&&stage==0&&event_id==1)||bounded_pos>=event_sample);
   skip_q<=tail_mode?(event_id<`P_TAIL_LAST&&(tail_wrapped||(next_tick!=58&&{2'd0,steam_pos}>=next_event_sample))):
    (event_id<last_event(stage)&&bounded_pos>=next_event_sample);
  end
 end
 assign commit_due=!pause&&!restart&&!request&&!skip_q&&load_ready&&due_q;
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   stage<=0;seen_voice<=0;fast_q<=0;running<=0;issued<=0;tail_mode<=0;tail_wrapped<=0;
   fast_pos<=0;steam_pos<=0;sample_div<=0;sample_phase<=0;request<=0;event_id<=0;epoch<=0;
  end else begin
   request<=0;fast_q<=fast_mode;
   if(virtual_step)begin sample_div<=0;sample_phase<=sample_phase==2?0:sample_phase+1'b1;end
   else sample_div<=sample_div+1'b1;
   if(restart)begin
    stage<=restart_stage;epoch<=epoch+1'b1;request<=1;issued<=1;
    event_id<=fast_mode&&restart_stage==0?9'd1:first_event(restart_stage);
    tail_mode<=0;tail_wrapped<=0;steam_pos<=0;fast_pos<=fast_mode&&restart_stage==0?19'd68400:19'd0;
    // PCM can start after display_ready but before the panel's next complete
    // scan boundary. Releasing Logo must retain that captured voice epoch.
    running<=fast_mode||voice_restart||(startup_release&&running&&voice_track_q==restart_stage);
    if(voice_restart)seen_voice<=voice_epoch;
   end else begin
    if(fast_mode&&!pause&&virtual_step&&fast_pos<duration(stage))fast_pos<=fast_pos+1'b1;
    if(ending&&!pause&&virtual_step)begin
     if(steam_pos==111359)begin steam_pos<=0;tail_wrapped<=1;end
     else steam_pos<=steam_pos+1'b1;
    end
    if(commit_pulse)begin
     if(!tail_mode&&event_id<last_event(stage))begin event_id<=event_id+1'b1;request<=1;end
     else if(tail_mode)begin
      event_id<=event_id==`P_TAIL_LAST?`P_TAIL_FIRST:event_id+1'b1;request<=1;
      if(event_id==`P_TAIL_LAST)tail_wrapped<=0;
     end else issued<=0;
    end else if(load_ready&&skip_q&&!pause&&!request)begin
     // The next dependency is already due: extend the hidden image in place.
     event_id<=event_id+1'b1;request<=1;
    end else if(!issued&&ending)begin
     tail_mode<=1;event_id<=`P_TAIL_FIRST;request<=1;issued<=1;
    end
   end
  end
 end


 // Store the three adjacent levels together, using spare BRAM9K to remove
 // runtime word/slot arithmetic and the six-read refill state machine.
 function[9:0]initial_index;input[1:0]s;begin case(s)
 0:initial_index=52;1:initial_index=307;2:initial_index=540;default:initial_index=753;endcase end endfunction
 function[18:0]initial_next;input[1:0]s;begin case(s)
 0:initial_next=960;1:initial_next=396;2:initial_next=1695;default:initial_next=370;endcase end endfunction
 reg[9:0]vindex;reg[11:0]mindex;reg[18:0]vnext;reg[21:0]mnext,music_old;
 wire[8:0]vword,mword;
 wire[2:0]v0=vword[2:0],v1=vword[5:3],v2=vword[8:6];
 wire[2:0]m0=mword[2:0],m1=mword[5:3],m2=mword[8:6];
 panel_envelope_rom u_envelope(clk,1'b1,{2'd0,vindex},vword,mindex,mword);
 always @(posedge clk or posedge rst)begin
  if(rst)begin vindex<=52;vnext<=960;mindex<=1006;mnext<=960;music_old<=0;end
  else begin
   music_old<=music_pos;
   if(restart)begin vindex<=initial_index(restart_stage);vnext<=initial_next(restart_stage);end
   else if(running&&voice_track_q==stage&&voice_pos>=vnext&&vnext<duration(stage))begin
    vindex<=vindex+1'b1;vnext<=vnext+19'd1920;
   end
   if(music_pos<music_old)begin mindex<=1006;mnext<=960;end
   else if(music_pos>=mnext)begin mindex<=mindex+1'b1;mnext<=mnext+22'd1920;end
  end
 end

 // Exact precomputed sample thresholds. Prefetch one record, hold it until
 // due, and atomically publish the packed geometry; audio remains independent.
 function[11:0]control_first;input[1:0]s;begin case(s)
 0:control_first=`P_CTRL_FIRST_0;1:control_first=`P_CTRL_FIRST_1;2:control_first=`P_CTRL_FIRST_2;default:control_first=`P_CTRL_FIRST_3;endcase end endfunction
 function[11:0]control_last;input[1:0]s;begin case(s)
 0:control_last=`P_CTRL_LAST_0;1:control_last=`P_CTRL_LAST_1;2:control_last=`P_CTRL_LAST_2;default:control_last=`P_CTRL_LAST_3;endcase end endfunction
 reg[1:0]control_state,control_part;
 reg[11:0]control_pointer;
 reg[15:0]control_low,control_middle;
 reg[44:0]pending_control;
 reg[25:0]geometry;
 wire[15:0]control_data;
 wire[44:0]control_record={control_data[12:0],control_middle,control_low};
 panel_control_rom u_control(clk,control_state==0,control_pointer,control_data);
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   control_state<=3;control_part<=0;control_pointer<=0;control_low<=0;control_middle<=0;pending_control<=0;geometry<=0;
  end else if(restart)begin
   control_state<=0;control_part<=0;control_pointer<=control_first(restart_stage);
  end else if(!pause)case(control_state)
   0:control_state<=1;
   1:begin
    if(control_part==0)begin control_low<=control_data;control_part<=1;control_pointer<=control_pointer+1'b1;control_state<=0;end
    else if(control_part==1)begin control_middle<=control_data;control_part<=2;control_pointer<=control_pointer+1'b1;control_state<=0;end
    else begin pending_control<=control_record;control_state<=2;end
   end
   2:if(bounded_pos>=pending_control[44:26])begin
    geometry<=pending_control[25:0];
    if(control_pointer>=control_last(stage))control_state<=3;
    else begin control_part<=0;control_pointer<=control_pointer+1'b1;control_state<=0;end
   end
   3:;
  endcase
 end
 wire[3:0]corner_focus=geometry[7:4];
 // First narration uses the material frame at sample 0; release its frame and
 // waveform window with real PCM playback instead of waiting for the first
 // pour cue to enable geometry[1].  Preserve the original audio envelopes.
 wire first_voice_ornaments=(stage==2'd0)&&voice_active&&!fast_mode;
 wire fast_beans=fast_mode&&stage==0&&bounded_pos<19'd77040;
 always @(posedge clk or posedge rst)begin
  if(rst)render_state<=0;
  else if(!pause)render_state<={stage,2'd0,
   (fast_beans?3'd0:geometry[25:23]),(fast_beans?1'b0:geometry[22]),
   (fast_beans?7'd88:geometry[21:15]),(fast_beans?3'd7:geometry[14:12]),
   (voice_active&&!fast_mode?v0:3'd0),(voice_active&&!fast_mode?v1:3'd0),(voice_active&&!fast_mode?v2:3'd0),
   (music_active?m0:3'd0),(music_active?m1:3'd0),(music_active?m2:3'd0),geometry[11:8],
   (corner_focus>12?4'd12:corner_focus),corner_focus,geometry[3],geometry[2],
   (geometry[0]?3'd6:3'd3+(music_active&&m0>=4)+(music_active&&m0>=6)),
   (geometry[1]||first_voice_ornaments),tail_mode};
 end
endmodule
`endif
