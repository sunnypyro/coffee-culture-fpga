// Frame-rate subtitle/callout scheduler.
//
// The timing table is scanned once after a new playback frame is identified.
// One subtitle/callout entry is decoded per video clock instead of building
// all 21 interval comparators in parallel.  The scan finishes during the
// vertical blanking interval; the resulting buses remain stable for the rest
// of the displayed frame.  All eight callouts can still be active together.
module osd_controller (
    input  wire       video_clk,
    input  wire       rst,
    input  wire       vs_in,
    input  wire       display_valid,
    input  wire [1:0] track_id,
    input  wire       track_start_video,
    input  wire       playback_start_video,
    input  wire       pause_state,

    output reg        subtitle_active,
    output reg [4:0]  subtitle_id,
    output reg [1:0]  subtitle_level,

    output reg [7:0]  callout_on,
    output reg [23:0] callout_alpha,
    output reg [23:0] callout_talpha,
    output reg [31:0] callout_grow
);
    `include "osd_timing_table.vh"

    localparam [16:0] LAST_OSD_FRAME = 17'd100011;
    localparam [4:0]  SUBTITLE_COUNT = 5'd13;
    localparam [4:0]  EVENT_COUNT    = 5'd21;

    reg        vs_d;
    reg        playing;
    reg [16:0] elapsed_frame;
    wire       frame_start = vs_in & ~vs_d;
    wire [16:0] next_elapsed_frame =
        (elapsed_frame < LAST_OSD_FRAME) ? (elapsed_frame + 17'd1) : elapsed_frame;

    reg        scan_active;
    reg [4:0]  scan_index;
    reg [16:0] scan_frame;
    reg [1:0]  scan_track;

    reg        subtitle_active_acc;
    reg [4:0]  subtitle_id_acc;
    reg [1:0]  subtitle_level_acc;
    reg [7:0]  callout_on_acc;
    reg [23:0] callout_alpha_acc;
    reg [23:0] callout_talpha_acc;
    reg [31:0] callout_grow_acc;

    reg [2:0]  scan_callout_id;
    reg [16:0] c_show;
    reg [16:0] c_fade;
    reg [16:0] c_t0;
    reg [16:0] c_t1;
    reg [16:0] c_t2;
    reg [2:0]  c_dot;
    reg [2:0]  c_text;
    reg [2:0]  c_fade_level;
    reg [3:0]  c_grow;
    reg [2:0]  c_alpha;
    reg [2:0]  c_talpha;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            vs_d          <= 1'b0;
            playing       <= 1'b0;
            elapsed_frame <= 17'd0;
        end else begin
            vs_d <= vs_in;
            if (track_start_video) begin
                playing       <= 1'b0;
                elapsed_frame <= 17'd0;
            end else if (playback_start_video) begin
                playing       <= 1'b1;
                elapsed_frame <= 17'd0;
            end else if (!pause_state && playing && frame_start &&
                         (elapsed_frame < LAST_OSD_FRAME)) begin
                elapsed_frame <= elapsed_frame + 17'd1;
            end
        end
    end

    always @* begin
        scan_callout_id = (scan_index >= SUBTITLE_COUNT)
                        ? scan_index[2:0] - 3'd5 : 3'd0;
        c_show = 17'd0;
        c_fade = LAST_OSD_FRAME;
        c_t0 = 17'd0;
        c_t1 = 17'd0;
        c_t2 = 17'd0;
        c_dot = 3'd0;
        c_text = 3'd0;
        c_fade_level = 3'd0;
        c_grow = 4'd0;
        c_alpha = 3'd0;
        c_talpha = 3'd0;

        if ((scan_index >= SUBTITLE_COUNT) && (scan_index < EVENT_COUNT)) begin
            c_show = osd_callout_show(scan_callout_id);
            c_fade = osd_callout_fade(scan_callout_id);
            c_t0 = c_show - 17'd20;
            c_t1 = c_show - 17'd14;
            c_t2 = c_show - 17'd6;

            if (scan_frame < c_t0 + 17'd2)       c_dot = 3'd1;
            else if (scan_frame < c_t0 + 17'd4)  c_dot = 3'd2;
            else if (scan_frame < c_t1)          c_dot = 3'd3;
            else                                  c_dot = 3'd4;

            if (scan_frame < c_t1)
                c_grow = 4'd0;
            else if (scan_frame < c_t2)
                c_grow = scan_frame - c_t1 + 17'd1;
            else
                c_grow = 4'd8;

            if      (scan_frame < c_t2)          c_text = 3'd0;
            else if (scan_frame < c_t2 + 17'd2) c_text = 3'd1;
            else if (scan_frame < c_t2 + 17'd4) c_text = 3'd2;
            else if (scan_frame < c_show)        c_text = 3'd3;
            else                                 c_text = 3'd4;

            if      (scan_frame < c_fade)         c_fade_level = 3'd4;
            else if (scan_frame < c_fade + 17'd3)  c_fade_level = 3'd3;
            else if (scan_frame < c_fade + 17'd6)  c_fade_level = 3'd2;
            else if (scan_frame < c_fade + 17'd9)  c_fade_level = 3'd1;
            else                                   c_fade_level = 3'd0;

            c_alpha  = (c_dot  < c_fade_level) ? c_dot  : c_fade_level;
            c_talpha = (c_text < c_fade_level) ? c_text : c_fade_level;
        end
    end

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            scan_active       <= 1'b0;
            scan_index        <= 5'd0;
            scan_frame        <= 17'd0;
            scan_track        <= 2'd0;
            subtitle_active_acc <= 1'b0;
            subtitle_id_acc     <= 5'd0;
            subtitle_level_acc  <= 2'd0;
            callout_on_acc      <= 8'd0;
            callout_alpha_acc   <= 24'd0;
            callout_talpha_acc  <= 24'd0;
            callout_grow_acc    <= 32'd0;
            subtitle_active   <= 1'b0;
            subtitle_id       <= 5'd0;
            subtitle_level    <= 2'd0;
            callout_on        <= 8'd0;
            callout_alpha     <= 24'd0;
            callout_talpha    <= 24'd0;
            callout_grow      <= 32'd0;
        end else if (track_start_video) begin
            scan_active       <= 1'b0;
            scan_index        <= 5'd0;
            scan_frame        <= 17'd0;
            scan_track        <= track_id;
            subtitle_active_acc <= 1'b0;
            subtitle_id_acc     <= 5'd0;
            subtitle_level_acc  <= 2'd0;
            callout_on_acc      <= 8'd0;
            callout_alpha_acc   <= 24'd0;
            callout_talpha_acc  <= 24'd0;
            callout_grow_acc    <= 32'd0;
            subtitle_active   <= 1'b0;
            subtitle_id       <= 5'd0;
            subtitle_level    <= 2'd0;
            callout_on        <= 8'd0;
            callout_alpha     <= 24'd0;
            callout_talpha    <= 24'd0;
            callout_grow      <= 32'd0;
        end else if (!display_valid) begin
            scan_active       <= 1'b0;
            scan_index        <= 5'd0;
            subtitle_active_acc <= 1'b0;
            subtitle_id_acc     <= 5'd0;
            subtitle_level_acc  <= 2'd0;
            callout_on_acc      <= 8'd0;
            callout_alpha_acc   <= 24'd0;
            callout_talpha_acc  <= 24'd0;
            callout_grow_acc    <= 32'd0;
            subtitle_active   <= 1'b0;
            subtitle_id       <= 5'd0;
            subtitle_level    <= 2'd0;
            callout_on        <= 8'd0;
            callout_alpha     <= 24'd0;
            callout_talpha    <= 24'd0;
            callout_grow      <= 32'd0;
        end else if (playback_start_video) begin
            scan_active       <= 1'b1;
            scan_index        <= 5'd0;
            scan_frame        <= 17'd0;
            scan_track        <= track_id;
            subtitle_active_acc <= 1'b0;
            subtitle_id_acc     <= 5'd0;
            subtitle_level_acc  <= 2'd0;
            callout_on_acc      <= 8'd0;
            callout_alpha_acc   <= 24'd0;
            callout_talpha_acc  <= 24'd0;
            callout_grow_acc    <= 32'd0;
            subtitle_active   <= 1'b0;
            subtitle_id       <= 5'd0;
            subtitle_level    <= 2'd0;
            callout_on        <= 8'd0;
            callout_alpha     <= 24'd0;
            callout_talpha    <= 24'd0;
            callout_grow      <= 32'd0;
        end else if (frame_start && playing && !pause_state) begin
            scan_active       <= 1'b1;
            scan_index        <= 5'd0;
            scan_frame        <= next_elapsed_frame;
            scan_track        <= track_id;
            subtitle_active_acc <= 1'b0;
            subtitle_id_acc     <= 5'd0;
            subtitle_level_acc  <= 2'd0;
            callout_on_acc      <= 8'd0;
            callout_alpha_acc   <= 24'd0;
            callout_talpha_acc  <= 24'd0;
            callout_grow_acc    <= 32'd0;
        end else if (scan_active) begin
            if (scan_index < SUBTITLE_COUNT) begin
                if ((osd_sub_track(scan_index) == scan_track) &&
                    (scan_frame >= osd_sub_start(scan_index)) &&
                    (scan_frame <= osd_sub_end(scan_index))) begin
                    subtitle_active_acc <= 1'b1;
                    subtitle_id_acc <= scan_index;
                    if ((scan_frame < osd_sub_start(scan_index) + 17'd2) ||
                        (scan_frame + 17'd2 > osd_sub_end(scan_index)))
                        subtitle_level_acc <= 2'd1;
                    else
                        subtitle_level_acc <= 2'd2;
                end
                scan_index <= scan_index + 5'd1;
            end else if (scan_index < EVENT_COUNT) begin
                if ((osd_callout_track(scan_callout_id) == scan_track) &&
                    (scan_frame >= c_show - 17'd20) &&
                    (scan_frame <  c_fade + 17'd12)) begin
                    callout_on_acc[scan_callout_id] <= 1'b1;
                    callout_alpha_acc[scan_callout_id*3 +: 3] <= c_alpha;
                    callout_talpha_acc[scan_callout_id*3 +: 3] <= c_talpha;
                    callout_grow_acc[scan_callout_id*4 +: 4] <= c_grow;
                end
                scan_index <= scan_index + 5'd1;
            end else begin
                subtitle_active <= subtitle_active_acc;
                subtitle_id <= subtitle_id_acc;
                subtitle_level <= subtitle_level_acc;
                callout_on <= callout_on_acc;
                callout_alpha <= callout_alpha_acc;
                callout_talpha <= callout_talpha_acc;
                callout_grow <= callout_grow_acc;
                scan_active <= 1'b0;
                scan_index <= 5'd0;
            end
        end
    end
endmodule
