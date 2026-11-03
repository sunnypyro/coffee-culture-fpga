`ifndef F06_STARTUP_VIDEO_VH
`define F06_STARTUP_VIDEO_VH
// 256x192 packed single-buffer intro, 2/5-phase bilinear coverage lookup.
// All 32K memories are SP. Two cached row pairs isolate scanout from updates.
module f06_startup_video (
    input wire clk, input wire rst, input wire video_locked,
    input wire hs_in, input wire vs_in, input wire de_in,
    input wire [23:0] rgb_in, input wire first_image_ready,
    input wire boot_ready, input wire restart,
    output reg hs_out, output reg vs_out, output reg de_out,
    output wire [23:0] rgb_out, output reg display_ready, output reg started
);
    reg vs_q, de_q;
    wire boundary=vs_q && !vs_in;
    wire line_start=de_in && !de_q;
    wire line_end=de_q && !de_in;
    reg [1:0] lock_sync;
    reg [14:0] ms_div;
    reg [12:0] elapsed_ms, next_due;
    reg [6:0] next_frame;
    reg [5:0] end_hold_count;
    localparam [5:0] END_HOLD_FRAMES = 6'd30; // 60 Hz: about 0.50 s; tune here
    reg first_image_armed, initialized, vertical_blank;
    reg intro_d, draw_d;
    reg [23:0] pass_rgb;
    wire [11:0] mixed_rgb;
    // Keep the screen black until the common boot start, so the panel and
    // HDMI animation become visible together. Frame 0 is only shown after
    // `started`, not while waiting for the display to re-link.
    assign rgb_out=!started ? 24'd0 : !intro_d ? pass_rgb : !draw_d ? 24'd0 :
        {mixed_rgb[11:8],mixed_rgb[11:8],mixed_rgb[7:4],mixed_rgb[7:4],mixed_rgb[3:0],mixed_rgb[3:0]};

    localparam D_IDLE=0,D_CLEAR=1,D_DIR0=2,D_WAIT0=3,D_DIR1=4,D_WAIT1=5,
        D_FETCH=6,D_WAIT_CMD=7,D_DECODE=8,D_READ=9,D_CAPTURE=10,D_WRITE=11;
    reg [3:0] ds;
    reg [12:0] rom_addr, command_ptr, frame_end;
    reg [15:0] cursor;
    reg [4:0] run_left;
    reg [1:0] color;
    reg [7:0] old_byte;
    wire [15:0] command;
    wire [15:0] advance=ds==D_CLEAR ? 16'd4 : ds==D_WRITE ? 16'd1 :
        command[1:0]==3 ? {2'd0,command[15:2]} : {6'd0,command[15:6]};
    wire [15:0] cursor_next=cursor+advance;
    wire decoder_busy=ds!=D_IDLE;
    wire [7:0] pixel_mask=8'h03 << {cursor[1:0],1'b0};
    wire [7:0] merged_byte=(old_byte & ~pixel_mask) | ({6'd0,color} << {cursor[1:0],1'b0});
    wire frame_we=vertical_blank && !de_in && (ds==D_CLEAR || ds==D_WRITE);
    wire [7:0] frame_q;
    wire [13:0] frame_addr;
    f06_sp_memory #(.AW(13),.DEPTH(5643),
        .INIT_FILE("../../../td_project/startup_assets/startup_coffee.mif")) u_stream (
        .clk(clk),.ce(1'b1),.we(1'b0),.addr(rom_addr),.din(16'd0),.dout(command));
    f06_sp_memory #(.WIDTH(8),.AW(14),.DEPTH(12288),.IMPLEMENT("32K"),
        .INIT_FILE("../../../td_project/startup_assets/startup_blank.mif")) u_pixels (
        .clk(clk),.ce(1'b1),.we(frame_we),.addr(frame_addr),
        .din(ds==D_CLEAR ? 8'd0 : merged_byte),.dout(frame_q));

    localparam L_IDLE=0,L_TOP=1,L_TOP_CAP=2,L_BOTTOM=3,L_BOTTOM_CAP=4,L_WRITE=5;
    reg [2:0] ls;
    reg [7:0] load_row;
    wire [7:0] load_bottom=load_row==191 ? 8'd191 : load_row+1'b1;
    reg [5:0] load_col;
    reg load_bank, priming, prime_request, prime_valid, next_pair_ready;
    reg display_bank;
    reg [7:0] load_top;
    reg [15:0] cache_write;
    wire [7:0] load_read_row=(ls==L_TOP || ls==L_TOP_CAP) ? load_row : load_bottom;
    assign frame_addr=decoder_busy ? cursor[15:2] : {load_read_row,load_col};
    wire [15:0] cache_q;
    reg [1:0] blank_phase;
    reg [3:0] group_pixel;
    reg [5:0] word_col;
    reg [15:0] word_a, word_b;
    reg [7:0] source_y;
    reg [2:0] phase_y;
    reg [8:0] output_y;
    wire [7:0] following_y=source_y==191 ? 8'd191 : source_y+(phase_y>=3);
    wire [5:0] lookahead_col=word_col>=62 ? 6'd63 : word_col+6'd2;
    wire [6:0] cache_read_addr={display_bank,de_in ? lookahead_col : (blank_phase==0 ? 6'd0 : 6'd1)};
    f06_line_cache u_lines (.clk(clk),.read_addr(cache_read_addr),.pixels(cache_q),
        .we(ls==L_WRITE && !decoder_busy),.write_addr({load_bank,load_col}),.write_pixels(cache_write));

    reg [1:0] local_x;
    reg [2:0] phase_x;
    always @* begin
        case(group_pixel)
            0: begin local_x=0;phase_x=0;end
            1: begin local_x=0;phase_x=2;end
            2: begin local_x=0;phase_x=4;end
            3: begin local_x=1;phase_x=1;end
            4: begin local_x=1;phase_x=3;end
            5: begin local_x=2;phase_x=0;end
            6: begin local_x=2;phase_x=2;end
            7: begin local_x=2;phase_x=4;end
            8: begin local_x=3;phase_x=1;end
            default: begin local_x=3;phase_x=3;end
        endcase
    end
    wire [2:0] shift_x={local_x,1'b0};
    wire [1:0] p00=word_a[shift_x +: 2];
    wire [1:0] p01=word_a[(4'd8+{1'b0,shift_x}) +: 2];
    wire [1:0] p10=local_x==3 ? (word_col==63 ? p00 : word_b[1:0]) : word_a[(4'd2+{1'b0,shift_x}) +: 2];
    wire [1:0] p11=local_x==3 ? (word_col==63 ? p01 : word_b[9:8]) : word_a[(4'd10+{1'b0,shift_x}) +: 2];
    function [19:0] weights;
        input [5:0] phase;
        begin case(phase)
            6'd0: weights={5'd25,5'd0,5'd0,5'd0};
            6'd1: weights={5'd20,5'd5,5'd0,5'd0};
            6'd2: weights={5'd15,5'd10,5'd0,5'd0};
            6'd3: weights={5'd10,5'd15,5'd0,5'd0};
            6'd4: weights={5'd5,5'd20,5'd0,5'd0};
            6'd8: weights={5'd20,5'd0,5'd5,5'd0};
            6'd9: weights={5'd16,5'd4,5'd4,5'd1};
            6'd10: weights={5'd12,5'd8,5'd3,5'd2};
            6'd11: weights={5'd8,5'd12,5'd2,5'd3};
            6'd12: weights={5'd4,5'd16,5'd1,5'd4};
            6'd16: weights={5'd15,5'd0,5'd10,5'd0};
            6'd17: weights={5'd12,5'd3,5'd8,5'd2};
            6'd18: weights={5'd9,5'd6,5'd6,5'd4};
            6'd19: weights={5'd6,5'd9,5'd4,5'd6};
            6'd20: weights={5'd3,5'd12,5'd2,5'd8};
            6'd24: weights={5'd10,5'd0,5'd15,5'd0};
            6'd25: weights={5'd8,5'd2,5'd12,5'd3};
            6'd26: weights={5'd6,5'd4,5'd9,5'd6};
            6'd27: weights={5'd4,5'd6,5'd6,5'd9};
            6'd28: weights={5'd2,5'd8,5'd3,5'd12};
            6'd32: weights={5'd5,5'd0,5'd20,5'd0};
            6'd33: weights={5'd4,5'd1,5'd16,5'd4};
            6'd34: weights={5'd3,5'd2,5'd12,5'd8};
            6'd35: weights={5'd2,5'd3,5'd8,5'd12};
            6'd36: weights={5'd1,5'd4,5'd4,5'd16};
            default: weights={5'd25,15'd0};
        endcase end
    endfunction
    wire [19:0] w=weights({phase_y,phase_x});
    wire [4:0] gold=(p00==1 ? w[19:15] : 5'd0)+(p10==1 ? w[14:10] : 5'd0)+
        (p01==1 ? w[9:5] : 5'd0)+(p11==1 ? w[4:0] : 5'd0);
    wire [4:0] white_sum=(p00==2 ? w[19:15] : 5'd0)+(p10==2 ? w[14:10] : 5'd0)+
        (p01==2 ? w[9:5] : 5'd0)+(p11==2 ? w[4:0] : 5'd0);
    function [8:0] triangle_base;
        input [4:0] g;
        begin case(g)
            5'd0: triangle_base=9'd0;
            5'd1: triangle_base=9'd26;
            5'd2: triangle_base=9'd51;
            5'd3: triangle_base=9'd75;
            5'd4: triangle_base=9'd98;
            5'd5: triangle_base=9'd120;
            5'd6: triangle_base=9'd141;
            5'd7: triangle_base=9'd161;
            5'd8: triangle_base=9'd180;
            5'd9: triangle_base=9'd198;
            5'd10: triangle_base=9'd215;
            5'd11: triangle_base=9'd231;
            5'd12: triangle_base=9'd246;
            5'd13: triangle_base=9'd260;
            5'd14: triangle_base=9'd273;
            5'd15: triangle_base=9'd285;
            5'd16: triangle_base=9'd296;
            5'd17: triangle_base=9'd306;
            5'd18: triangle_base=9'd315;
            5'd19: triangle_base=9'd323;
            5'd20: triangle_base=9'd330;
            5'd21: triangle_base=9'd336;
            5'd22: triangle_base=9'd341;
            5'd23: triangle_base=9'd345;
            5'd24: triangle_base=9'd348;
            5'd25: triangle_base=9'd350;
            default: triangle_base=0;
        endcase end
    endfunction
    wire [8:0] mix_addr=triangle_base(gold)+{4'd0,white_sum};
    f06_sp_memory #(.WIDTH(12),.AW(9),.DEPTH(351),.IMPLEMENT("9K"),
        .INIT_FILE("../../../td_project/startup_assets/startup_coverage.mif")) u_coverage (
        .clk(clk),.ce(1'b1),.we(1'b0),.addr(mix_addr),.din(12'd0),.dout(mixed_rgb));

    // Output timing never resets on a KEY1 restart: the HDMI core/PHY retain
    // the TMDS link and the AXIS frame timing stays continuous. Only a PLL
    // loss (rst) restarts it.
    wire anim_rst = rst | restart;
    always @(posedge clk or posedge rst) begin
        if(rst) begin
            vs_q<=0;de_q<=0;hs_out<=0;vs_out<=0;de_out<=0;pass_rgb<=0;
            lock_sync<=0;
        end else begin
            vs_q<=vs_in;de_q<=de_in;lock_sync<={lock_sync[0],video_locked};
            hs_out<=hs_in;vs_out<=vs_in;de_out<=de_in;
            pass_rgb<=rgb_in;
        end
    end

    // Animation/decoder/scan state restarts on KEY1; the timing above keeps
    // running, so panel and HDMI animation restart together and overlays stay
    // aligned.
    always @(posedge clk or posedge anim_rst) begin
        if(anim_rst) begin
            intro_d<=1;draw_d<=0;started<=0;display_ready<=0;first_image_armed<=0;
            ms_div<=0;elapsed_ms<=0;next_due<=0;next_frame<=0;end_hold_count<=0;initialized<=0;vertical_blank<=0;
            ds<=D_IDLE;rom_addr<=0;command_ptr<=0;frame_end<=0;cursor<=0;run_left<=0;color<=0;old_byte<=0;
            ls<=L_IDLE;load_row<=0;load_col<=0;load_bank<=0;load_top<=0;cache_write<=0;
            priming<=0;prime_request<=0;prime_valid<=0;next_pair_ready<=0;display_bank<=0;
            blank_phase<=0;group_pixel<=0;word_col<=0;word_a<=0;word_b<=0;source_y<=0;phase_y<=0;output_y<=0;
        end else begin
            intro_d<=!display_ready;draw_d<=prime_valid;
            if(de_in) begin
                if(group_pixel==9) begin
                    group_pixel<=0;
                    if(word_col<63) begin word_col<=word_col+1'b1;word_a<=word_b;word_b<=cache_q;end
                end else group_pixel<=group_pixel+1'b1;
            end else begin
                group_pixel<=0;word_col<=0;
                if(prime_valid) case(blank_phase)
                    0: blank_phase<=1;
                    1: begin word_a<=cache_q;blank_phase<=2;end
                    2: begin word_b<=cache_q;blank_phase<=3;end
                    default: ;
                endcase
            end
            if(line_start) begin
                vertical_blank<=0;
                if(prime_valid && output_y<479 && following_y!=source_y && ls==L_IDLE) begin
                    load_row<=following_y;load_col<=0;load_bank<=!display_bank;
                    priming<=0;next_pair_ready<=0;ls<=L_TOP;
                end
            end
            if(line_end) begin
                source_y<=following_y;phase_y<=phase_y>=3 ? phase_y-3'd3 : phase_y+3'd2;
                output_y<=output_y+1'b1;blank_phase<=0;
                if(next_pair_ready) begin display_bank<=!display_bank;next_pair_ready<=0;end
            end
            if(started && elapsed_ms<4250) begin
                if(ms_div==24999) begin ms_div<=0;elapsed_ms<=elapsed_ms+1'b1;end
                else ms_div<=ms_div+1'b1;
            end
            if(boundary) begin
                source_y<=0;phase_y<=0;output_y<=0;vertical_blank<=1;
                first_image_armed<=first_image_ready;prime_valid<=0;next_pair_ready<=0;
                prime_request<=!display_ready;ls<=L_IDLE;blank_phase<=0;
                if(!initialized && ds==D_IDLE) begin ds<=D_CLEAR;cursor<=0;end
                if(!started) begin
                    // Start at the first safe frame, after frame zero and its
                    // row cache exist, and after the common boot-ready gate
                    // (cold boot waits for the display to re-link).
                    if(lock_sync[1] && boot_ready && initialized && next_frame!=0 &&
                       !decoder_busy && prime_valid) started<=1;
                end else if(!display_ready && ds==D_IDLE) begin
                    if(next_frame<85 && elapsed_ms>=next_due) begin rom_addr<={6'd0,next_frame};ds<=D_DIR0;end
                    else if(next_frame==85 && elapsed_ms>=4250 && prime_valid && output_y==480) begin
                        // Hold complete VS intervals after the final animation
                        // frame has been scanned. At 60 Hz, 30 intervals are
                        // about 0.50 s. The counter saturates while the first
                        // image is still loading, so the final frame stays.
                        if(end_hold_count<END_HOLD_FRAMES) end_hold_count<=end_hold_count+1'b1;
                        else if(first_image_ready && first_image_armed) display_ready<=1;
                    end
                end
            end
            case(ds)
                D_CLEAR: if(frame_we) begin
                    if(cursor==16'd49148) begin cursor<=0;rom_addr<=0;initialized<=1;ds<=D_DIR0;end
                    else cursor<=cursor_next;
                end
                D_DIR0: ds<=D_WAIT0;
                D_WAIT0: begin command_ptr<=command[12:0];rom_addr<={6'd0,next_frame}+13'd1;ds<=D_DIR1;end
                D_DIR1: ds<=D_WAIT1;
                D_WAIT1: begin frame_end<=command[12:0];cursor<=0;ds<=D_FETCH;end
                D_FETCH: if(command_ptr>=frame_end) begin
                    next_frame<=next_frame+1'b1;next_due<=next_due+13'd50;ds<=D_IDLE;prime_request<=1;
                end else begin rom_addr<=command_ptr;ds<=D_WAIT_CMD;end
                D_WAIT_CMD: ds<=D_DECODE;
                D_DECODE: begin
                    command_ptr<=command_ptr+1'b1;cursor<=cursor_next;
                    if(command[1:0]==3) ds<=D_FETCH;
                    else begin run_left<={1'b0,command[5:2]}+5'd1;color<=command[1:0];ds<=D_READ;end
                end
                D_READ: if(vertical_blank && !de_in) ds<=D_CAPTURE;
                D_CAPTURE: begin old_byte<=frame_q;ds<=D_WRITE;end
                D_WRITE: if(frame_we) begin
                    cursor<=cursor_next;
                    if(run_left==1) ds<=D_FETCH;
                    else begin run_left<=run_left-1'b1;ds<=D_READ;end
                end
                default: ;
            endcase
            if(!boundary && !decoder_busy) begin
                case(ls)
                    L_IDLE: if(prime_request && initialized) begin
                        load_row<=0;load_col<=0;load_bank<=0;priming<=1;prime_request<=0;ls<=L_TOP;
                    end
                    L_TOP: ls<=L_TOP_CAP;
                    L_TOP_CAP: begin load_top<=frame_q;ls<=L_BOTTOM;end
                    L_BOTTOM: ls<=L_BOTTOM_CAP;
                    L_BOTTOM_CAP: begin cache_write<={frame_q,load_top};ls<=L_WRITE;end
                    L_WRITE: if(load_col==63) begin
                        ls<=L_IDLE;
                        if(priming) begin display_bank<=0;prime_valid<=1;blank_phase<=0;end
                        else next_pair_ready<=1;
                    end else begin load_col<=load_col+1'b1;ls<=L_TOP;end
                    default: ls<=L_IDLE;
                endcase
            end
        end
    end
endmodule
`endif
