`ifndef FOUR_GRID_PICKER_SCANOUT
`define FOUR_GRID_PICKER_SCANOUT
// One SDRAM read engine, two small read FIFOs.  All engine metadata is held
// until its final returned word; the pixel-side bank changes only in blanking.
module picker_scanout #(
 parameter integer FRAME_WORDS=307200,PREFIX_WORDS=256
)(
 input wire clk,rst,frame_req,input wire normal_source,override_enable,visible_toggle,
 input wire cmd_valid,cmd_cancel,input wire[7:0]cmd_id,input wire[1:0]cmd_source,
 output wire cmd_accept,output reg result_valid,input wire result_ready,
 output reg[7:0]result_id,output reg[1:0]result_code,result_source,
 input wire engine_ack,engine_done,empty0,empty1,
 output reg engine_req,output reg[20:0]engine_base,engine_len,
 output reg engine_append,job_bank,active_bank,output reg frame_ack,
 output reg[1:0]active_source,output wire engine_abort
);
 (* syn_preserve=1 *)reg[1:0]req_sync,norm_sync,override_sync,visible_sync,e0_sync,e1_sync;
 reg req_seen,visible_seen,frame_pending,busy,prefix_job;
 reg pending,locked,prefix_ready,same_source,candidate_bank,rebase_guard;
 reg[7:0]candidate_id,engine_candidate_id,last_id;
 reg[1:0]candidate_source,last_code,last_source;
 wire new_visible=visible_sync[1]!=visible_seen;
 wire cancelled_now=cmd_valid&&cmd_cancel&&cmd_id==candidate_id;
 wire candidate_visible=!candidate_bank?!e0_sync[1]:!e1_sync[1];
 wire can_commit=pending&&!locked&&prefix_ready&&candidate_visible&&!cancelled_now;
 assign cmd_accept=!result_valid&&(cmd_cancel||!pending);
 // A new video frame supersedes an unfinished ordinary full-frame read.
 // The engine stops only at a drained burst boundary. Keep job_bank and
 // the old metadata unchanged until engine_done, then dispatch the new frame.
 // Prefix jobs retain ownership until all their words have returned.
 assign engine_abort=busy&&!prefix_job&&!engine_req&&frame_pending;

 function[20:0]base_of;input[1:0]s;begin
  case(s)0:base_of=0;1:base_of=FRAME_WORDS;default:base_of=FRAME_WORDS*2;endcase
 end endfunction
 always @(posedge clk or posedge rst)begin
  if(rst)begin
   req_sync<=0;norm_sync<=0;override_sync<=0;visible_sync<=0;e0_sync<=3;e1_sync<=3;
   req_seen<=0;visible_seen<=0;frame_pending<=0;busy<=0;prefix_job<=0;
   pending<=0;locked<=0;prefix_ready<=0;same_source<=0;candidate_bank<=0;rebase_guard<=0;
   candidate_id<=0;engine_candidate_id<=0;candidate_source<=0;
   last_id<=0;last_code<=0;last_source<=0;
   engine_req<=0;engine_base<=0;engine_len<=FRAME_WORDS;engine_append<=0;
   job_bank<=0;active_bank<=0;active_source<=0;frame_ack<=0;
   result_valid<=0;result_id<=0;result_code<=0;result_source<=0;
  end else begin
   req_sync<={req_sync[0],frame_req};norm_sync<={norm_sync[0],normal_source};
   override_sync<={override_sync[0],override_enable};visible_sync<={visible_sync[0],visible_toggle};
   e0_sync<={e0_sync[0],empty0};e1_sync<={e1_sync[0],empty1};visible_seen<=visible_sync[1];
   // The menu-close flag and the legacy PIX selector use different CDC
   // paths. Keep the committed full source until that selector catches up.
   if(rebase_guard&&active_source!=2&&norm_sync[1]==active_source[0])rebase_guard<=0;
   if(result_valid&&result_ready)result_valid<=0;
   if(!req_sync[1])begin req_seen<=0;frame_ack<=0;end
   if(req_sync[1]&&!req_seen)begin frame_pending<=1;req_seen<=1;end
   if(engine_req&&engine_ack)engine_req<=0;
   if(busy&&engine_done)begin
    busy<=0;
    if(prefix_job&&pending&&!locked&&engine_candidate_id==candidate_id&&!cancelled_now)
     prefix_ready<=1;
   end
   if(cmd_valid&&cmd_accept)begin
    if(cmd_cancel)begin
     if(pending&&cmd_id==candidate_id&&!locked)begin
      pending<=0;prefix_ready<=0;result_valid<=1;result_id<=cmd_id;
      result_code<=1;result_source<=active_source;
      last_id<=cmd_id;last_code<=1;last_source<=active_source;
     end else if(!pending&&cmd_id==last_id)begin
      result_valid<=1;result_id<=last_id;result_code<=last_code;result_source<=last_source;
     end
    end else begin
     pending<=1;locked<=0;candidate_id<=cmd_id;candidate_source<=cmd_source;
     same_source<=cmd_source==active_source;prefix_ready<=cmd_source==active_source;
     candidate_bank<=cmd_source==active_source?active_bank:~active_bank;
    end
   end
   if(pending&&locked&&new_visible&&!result_valid)begin
    pending<=0;locked<=0;prefix_ready<=0;
    result_valid<=1;result_id<=candidate_id;result_code<=0;result_source<=candidate_source;
    last_id<=candidate_id;last_code<=0;last_source<=candidate_source;
   end
   if(!busy&&!engine_req)begin
    if(frame_pending)begin
     frame_pending<=0;frame_ack<=1;busy<=1;prefix_job<=0;engine_req<=1;
     if(can_commit)begin
      rebase_guard<=candidate_source!=2;
      locked<=1;active_source<=candidate_source;active_bank<=candidate_bank;
      job_bank<=candidate_bank;engine_append<=!same_source;
      engine_base<=base_of(candidate_source)+(same_source?0:PREFIX_WORDS);
      engine_len<=same_source?FRAME_WORDS:FRAME_WORDS-PREFIX_WORDS;
     end else begin
      job_bank<=active_bank;engine_append<=0;engine_len<=FRAME_WORDS;
      if(!override_sync[1]&&!rebase_guard)begin
       active_source<={1'b0,norm_sync[1]};engine_base<=base_of({1'b0,norm_sync[1]});
      end else engine_base<=base_of(active_source);
     end
    end else if(pending&&!locked&&!prefix_ready&&!cancelled_now)begin
     busy<=1;prefix_job<=1;engine_req<=1;engine_append<=0;
     job_bank<=candidate_bank;engine_candidate_id<=candidate_id;
     engine_base<=base_of(candidate_source);engine_len<=PREFIX_WORDS;
    end
   end
  end
 end
endmodule
`endif
