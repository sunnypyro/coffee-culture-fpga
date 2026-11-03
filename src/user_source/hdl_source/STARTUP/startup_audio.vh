`ifndef F06_STARTUP_AUDIO_VH
`define F06_STARTUP_AUDIO_VH
// Fixed-score hybrid instrument. Metadata occupies the spare six bits of the
// SAME 512x18 wave ROM. Rotating voice registers avoid wide indexed read muxes.
// One signed 18x18 multiplier serves interpolation, amplitude and release.
module f06_startup_audio (
    input wire clk, input wire rst, input wire started, input wire sample_tick,
    output reg signed [23:0] sample_out,
    output reg prepared
);
    localparam CLEAR=0,IDLE=1,CHECK_EVENT=2,CTRL_READ=3,CTRL_CAPTURE=4,CTRL_DONE=5,
        LOAD=6,BODY_WAIT=7,BODY=8,ATTACK_WAIT=9,BLEND=10,BLEND_GET=11,
        ENV_MUL=12,ENV_GET=13,RELEASE_MUL=14,RELEASE_GET=15,ACC=16,
        TAP0_WAIT=17,TAP0=18,TAP1_WAIT=19,TAP1=20,TAP2_WAIT=21,TAP2=22,
        OLD_WAIT=23,OLD=24,ECHO_WRITE=25,OUTPUT_GAIN=26;
    reg [4:0] state;
    reg [23:0] phase[0:6];
    reg [19:0] envelope[0:6];
    reg [9:0] age[0:6];
    reg [3:0] instrument[0:6];
    reg active[0:6], fading[0:6];
    reg [8:0] fade[0:6];
    reg [2:0] voice;
    reg [5:0] sub_sample;
    reg [12:0] elapsed_ms,time_ms,next_event_ms;
    reg [2:0] next_event_voice;
    reg next_event_fade,event_pending,update_envelope,finished;
    reg [3:0] event_ptr,control_note,control_part;
    reg control_is_event,initial_control;
    reg [71:0] control_record;
    wire [18:0] frequency=control_record[31:13];
    wire [19:0] target=control_record[51:32];
    wire [15:0] attack_step=control_record[67:52];
    wire [8:0] metadata_addr=({5'd0,control_note}<<3)+({5'd0,control_note}<<2)+{5'd0,control_part};
    reg [8:0] sample_addr;
    wire [8:0] wave_addr=(state==CTRL_READ || state==CTRL_CAPTURE || state==CTRL_DONE) ? metadata_addr : sample_addr;
    wire [17:0] wave_q;
    wire signed [11:0] wave_sample=wave_q[11:0];
    f06_sp_memory #(.WIDTH(18),.AW(9),.DEPTH(512),.IMPLEMENT("9K"),
        .INIT_FILE("../../../td_project/startup_assets/startup_wave.mif")) u_wave (
        .clk(clk),.ce(1'b1),.we(1'b0),.addr(wave_addr),.din(18'd0),.dout(wave_q));
    reg signed [12:0] body_sample,blend_sample;
    reg [19:0] env_work;
    reg [8:0] bright_gain,release_gain;
    reg signed [15:0] voice_sample,dry_sample;
    reg signed [21:0] accumulator;
    reg signed [19:0] echo_sum;
    reg [10:0] echo_pos,echo_addr,clear_addr;
    reg signed [15:0] echo_write_data;
    wire signed [15:0] echo_q;
    wire echo_we=(state==CLEAR || state==ECHO_WRITE);
    f06_sp_memory #(.WIDTH(16),.AW(11),.DEPTH(2048),.IMPLEMENT("32K"),
        .INIT_FILE("../../../td_project/startup_assets/startup_echo_zero.mif")) u_echo (
        .clk(clk),.ce(1'b1),.we(echo_we),.addr(state==CLEAR ? clear_addr : echo_addr),
        .din(state==CLEAR ? 16'd0 : echo_write_data),.dout(echo_q));

    function signed [15:0] sat16;
        input signed [21:0] v;
        begin
            if(v>22'sd32767) sat16=16'sh7fff;
            else if(v < -22'sd32768) sat16=16'sh8000;
            else sat16=v[15:0];
        end
    endfunction
    // Accumulation, ring feedback and output share one adder/limiter, rather
    // than synthesizing three parallel saturated add datapaths.
    reg signed [21:0] add_a,add_b;
    always @* begin
        add_a=0;add_b=0;
        case(state)
            ACC: begin add_a=accumulator;add_b=voice_sample;end
            OLD: begin add_a=dry_sample;add_b=echo_q>>>2;end
            ECHO_WRITE: begin add_a=dry_sample;add_b=echo_sum;end
            // Reuse this 22-bit adder and limiter for 2.5x final output.
            // The echo feedback remains at its original internal level.
            OUTPUT_GAIN: begin
                add_a=$signed({{6{dry_sample[15]}},dry_sample}) <<< 1;
                add_b=$signed({{6{dry_sample[15]}},dry_sample}) >>> 1;
            end
            default: ;
        endcase
    end
    wire signed [21:0] audio_sum=add_a+add_b;
    wire signed [15:0] limited_sum=sat16(audio_sum);
    // Only the head of each rotating bank is read. There is no 7:1 datapath mux.
    wire [19:0] env_decay=(voice>=4 || time_ms>=4080) ? envelope[0]>>8 : envelope[0]>>10;
    reg [19:0] next_env;
    wire [8:0] next_fade=update_envelope && fading[0] ?
        (fade[0]>13 ? fade[0]-9'd13 : 9'd0) : fade[0];
    always @* begin
        next_env=envelope[0];
        if(update_envelope) begin
            if((voice<4 && age[0]<12) || (voice>=4 && age[0]<550)) begin
                if(envelope[0]+{4'd0,attack_step}>target) next_env=target;
                else next_env=envelope[0]+{4'd0,attack_step};
            end else if(voice<4 || time_ms>=3800) begin
                if(envelope[0]==0) next_env=0;
                else next_env=envelope[0]-(env_decay==0 ? 20'd1 : env_decay);
            end
        end
    end
    reg signed [17:0] mul_a,mul_b;
    reg signed [35:0] product;
    always @* begin
        mul_a=0;mul_b=0;
        case(state)
            BLEND: begin mul_a=$signed(wave_sample)-$signed(body_sample);mul_b=$signed({9'd0,bright_gain});end
            ENV_MUL: begin mul_a=blend_sample;mul_b=$signed({2'd0,env_work[19:4]});end
            RELEASE_MUL: begin mul_a=voice_sample;mul_b=$signed({9'd0,release_gain});end
            default: ;
        endcase
    end
    always @(posedge clk) product<=mul_a*mul_b;
    integer i;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            prepared<=0;
            state<=CLEAR;sample_out<=0;voice<=0;sub_sample<=0;elapsed_ms<=0;time_ms<=0;
            next_event_ms<=0;next_event_voice<=0;next_event_fade<=0;event_pending<=0;
            update_envelope<=0;finished<=0;event_ptr<=0;control_note<=0;control_part<=0;
            control_is_event<=1;initial_control<=1;control_record<=0;sample_addr<=0;
            body_sample<=0;blend_sample<=0;env_work<=0;bright_gain<=0;release_gain<=256;
            voice_sample<=0;dry_sample<=0;accumulator<=0;echo_sum<=0;
            echo_pos<=0;echo_addr<=0;clear_addr<=0;echo_write_data<=0;
            for(i=0;i<7;i=i+1) begin
                phase[i]<=0;envelope[i]<=0;age[i]<=0;instrument[i]<=0;
                active[i]<=0;fading[i]<=0;fade[i]<=256;
            end
        end else case(state)
            CLEAR: if(clear_addr==2047) begin state<=CTRL_READ;control_part<=0;end
                else clear_addr<=clear_addr+1'b1;
            IDLE: if(started && !finished && sample_tick) begin
                if(elapsed_ms>=5650) begin finished<=1;sample_out<=0;end
                else begin
                    time_ms<=elapsed_ms;update_envelope<=(sub_sample==0);voice<=0;accumulator<=0;
                    if(sub_sample==47) begin sub_sample<=0;elapsed_ms<=elapsed_ms+1'b1;end
                    else sub_sample<=sub_sample+1'b1;
                    state<=CHECK_EVENT;
                end
            end
            CHECK_EVENT: if(event_pending && next_event_ms<=time_ms) begin
                for(i=0;i<7;i=i+1) if(next_event_voice==i) begin
                    if(next_event_fade) fading[i]<=1;
                    else begin
                        phase[i]<=0;envelope[i]<=0;age[i]<=0;instrument[i]<=event_ptr;
                        active[i]<=1;fading[i]<=0;fade[i]<=256;
                    end
                end
                if(event_ptr==14) begin event_pending<=0;state<=CHECK_EVENT;end
                else begin
                    event_ptr<=event_ptr+1'b1;control_note<=event_ptr+1'b1;
                    control_part<=0;control_is_event<=1;state<=CTRL_READ;
                end
            end else if(active[0]) begin
                control_note<=instrument[0];control_part<=0;control_is_event<=0;state<=CTRL_READ;
            end else begin voice_sample<=0;state<=ACC;end
            CTRL_READ: state<=CTRL_CAPTURE;
            CTRL_CAPTURE: begin
                control_record<={wave_q[17:12],control_record[71:6]};
                if(control_part==11) state<=CTRL_DONE;
                else begin control_part<=control_part+1'b1;state<=CTRL_READ;end
            end
            CTRL_DONE: if(control_is_event) begin
                next_event_ms<=control_record[12:0];next_event_voice<=control_record[70:68];
                next_event_fade<=control_record[71];event_pending<=1;
                if(initial_control) begin initial_control<=0;prepared<=1;state<=IDLE;end
                else state<=CHECK_EVENT;
            end else state<=LOAD;
            LOAD: begin
                env_work<=next_env;
                sample_addr<={1'b0,phase[0][23:16]};
                bright_gain<=voice<4 && age[0]<256 ? 9'd256-age[0][8:0] : 9'd0;
                release_gain<=next_fade;state<=BODY_WAIT;
            end
            BODY_WAIT: state<=BODY;
            BODY: begin body_sample<=wave_sample;sample_addr<={1'b1,sample_addr[7:0]};state<=ATTACK_WAIT;end
            ATTACK_WAIT: state<=BLEND;
            BLEND: state<=BLEND_GET;
            BLEND_GET: begin blend_sample<=body_sample+$signed(product>>>8);state<=ENV_MUL;end
            ENV_MUL: state<=ENV_GET;
            ENV_GET: begin voice_sample<=product>>>16;state<=RELEASE_MUL;end
            RELEASE_MUL: state<=RELEASE_GET;
            RELEASE_GET: begin voice_sample<=product>>>8;state<=ACC;end
            ACC: begin
                // Seven rotations restore original slot order before event programming.
                for(i=0;i<6;i=i+1) begin
                    phase[i]<=phase[i+1];envelope[i]<=envelope[i+1];age[i]<=age[i+1];
                    instrument[i]<=instrument[i+1];active[i]<=active[i+1];fading[i]<=fading[i+1];fade[i]<=fade[i+1];
                end
                phase[6]<=active[0] ? phase[0]+{5'd0,frequency} : phase[0];
                envelope[6]<=active[0] ? env_work : 20'd0;
                age[6]<=update_envelope && age[0]!=1023 ? age[0]+1'b1 : age[0];
                instrument[6]<=instrument[0];active[6]<=active[0];fading[6]<=fading[0];fade[6]<=next_fade;
                accumulator<=audio_sum;
                if(voice==6) begin dry_sample<=limited_sum;echo_addr<=echo_pos-11'd677;state<=TAP0_WAIT;end
                else begin
                    voice<=voice+1'b1;
                    // Event checks are NOT repeated after rotating bank indices.
                    control_note<=instrument[1];control_part<=0;control_is_event<=0;
                    if(active[1]) state<=CTRL_READ;
                    else begin voice_sample<=0;state<=ACC;end
                end
            end
            TAP0_WAIT: state<=TAP0;
            TAP0: begin echo_sum<=echo_q>>>3;echo_addr<=echo_pos-11'd1237;state<=TAP1_WAIT;end
            TAP1_WAIT: state<=TAP1;
            TAP1: begin echo_sum<=echo_sum+(echo_q>>>4);echo_addr<=echo_pos-11'd1999;state<=TAP2_WAIT;end
            TAP2_WAIT: state<=TAP2;
            TAP2: begin echo_sum<=echo_sum+(echo_q>>>4);echo_addr<=echo_pos;state<=OLD_WAIT;end
            OLD_WAIT: state<=OLD;
            OLD: begin echo_write_data<=limited_sum;state<=ECHO_WRITE;end
            ECHO_WRITE: begin
                dry_sample<=limited_sum;echo_pos<=echo_pos+1'b1;state<=OUTPUT_GAIN;
            end
            OUTPUT_GAIN: begin sample_out<={limited_sum,8'd0};state<=IDLE;end
            default: state<=IDLE;
        endcase
    end
endmodule
`endif
