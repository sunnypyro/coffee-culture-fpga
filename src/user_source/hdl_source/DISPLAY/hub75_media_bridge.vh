`ifndef F11_MEDIA_BRIDGE
`define F11_MEDIA_BRIDGE
// Passive observers. The held mailbox bus cannot change until destination ack.
module hub75_source_observer #(parameter W=19, parameter MUSIC=0,
    parameter STALE_CYCLES=50000)(
    input wire source_clk, input wire step, input wire start_toggle,
    input wire done, input wire [1:0] track, input wire available,
    input wire panel_clk, input wire rst,
    output reg [W+3:0] snapshot, output reg valid
);
    wire source_reset,panel_reset;
    picker_reset_release u_source_reset(source_clk,rst,source_reset);
    picker_reset_release u_panel_reset(panel_clk,rst,panel_reset);
    reg [W-1:0] position;
    reg epoch,active,started,start_seen,done_seen;
    reg [1:0] track0,track1,stage;
    reg [16:0] stale;
    reg [W+3:0] held;
    reg request,ack,dirty;
    (* syn_preserve=1 *) reg [1:0] ack_sync,request_sync;
    always @(posedge source_clk or posedge source_reset) begin
        if(source_reset)begin
            position<=0;epoch<=0;active<=0;started<=0;start_seen<=0;done_seen<=0;
            track0<=0;track1<=0;stage<=0;stale<=0;held<=0;request<=0;dirty<=0;ack_sync<=0;
        end else begin
            track0<=track;track1<=track0;ack_sync<={ack_sync[0],ack};
            start_seen<=start_toggle;done_seen<=done;
            if(request==ack_sync[1] && dirty) begin
                held<={epoch,stage,active,position};request<=~request;dirty<=0;
            end
            if(stale<STALE_CYCLES)stale<=stale+1'b1;
            if(stale==STALE_CYCLES-1 && active)begin active<=0;dirty<=1;end
            if(!available && active)begin active<=0;dirty<=1;end
            if(!MUSIC && start_toggle!=start_seen)begin
                position<=0;epoch<=~epoch;stage<=track1;started<=step;
                active<=step;stale<=0;dirty<=1;
            end else if(step)begin
                if(!started)begin position<=0;started<=1;end
                else if(MUSIC && position==2423999)begin position<=0;epoch<=~epoch;end
                else position<=position+1'b1;
                active<=1;stale<=0;dirty<=1;
            end else if(!MUSIC && done && !done_seen)begin
                if(started)position<=position+1'b1;
                active<=0;dirty<=1;
            end
        end
    end
    always @(posedge panel_clk or posedge panel_reset)begin
        if(panel_reset)begin request_sync<=0;ack<=0;snapshot<=0;valid<=0;end
        else begin
            request_sync<={request_sync[0],request};valid<=0;
            if(request_sync[1]!=ack)begin snapshot<=held;ack<=request_sync[1];valid<=1;end
        end
    end
endmodule

module hub75_media_bridge(
    input wire voice_clk, input wire voice_step, input wire voice_start_toggle,
    input wire voice_done, input wire [1:0] voice_track,
    input wire music_clk,input wire music_step,input wire music_available,
    input wire panel_clk,input wire rst,
    output wire voice_epoch,output wire [1:0] voice_track_q,
    output wire [18:0] voice_pos,output wire voice_active,
    output wire [21:0] music_pos,output wire music_active,output wire snapshot_valid
);
    wire [22:0] v;wire [25:0] m;wire vv,mv;
    hub75_source_observer #(.W(19),.STALE_CYCLES(50000)) u_voice(
        voice_clk,voice_step,voice_start_toggle,voice_done,voice_track,1'b1,panel_clk,rst,v,vv);
    hub75_source_observer #(.W(22),.MUSIC(1),.STALE_CYCLES(100000)) u_music(
        music_clk,music_step,1'b0,1'b0,2'd0,music_available,panel_clk,rst,m,mv);
    assign {voice_epoch,voice_track_q,voice_active,voice_pos}=v;
    assign music_pos=m[21:0];assign music_active=m[22];
    assign snapshot_valid=vv|mv;
endmodule
`endif
