// Shared subtitle/callout renderer for the 640x480 video stream.
//
// Chinese text is stored as a 14 px, 2-bit glyph atlas. A small character
// table selects one glyph per pixel; this avoids storing every whole line
// separately and keeps the font itself out of LUT logic. Callout ROIs are
// disjoint, so one selected geometry/line/dot path can serve all active
// callouts in the same frame. The picture_adjust block and video sidebands
// remain on the existing output path.
module video_osd_overlay #(
    parameter integer ENABLE_RES_READOUT = 1,
    parameter integer ENABLE_ADJ_READOUT = 1,
    parameter integer MODE_NOTICE_CYCLES = 75000000
)(
    input wire picker_plain,
    input wire picker_grid_visible,
    input wire [1:0] step_track_id,
    input wire step_pause,
    input wire step_transition_idle,
    input  wire        video_clk,
    input  wire        rst,
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire        de_in,
    input  wire [23:0] rgb_in,
    input  wire        display_valid,
    input  wire        auto_mode_async,
    input  wire        fast_mode_async,
    input  wire signed [4:0] brightness_level,
    input  wire signed [4:0] contrast_level,
    input  wire        subtitle_active,
    input  wire [4:0]  subtitle_id,
    input  wire [1:0]  subtitle_level,
    input  wire [7:0]  callout_on,
    input  wire [23:0] callout_alpha,
    input  wire [23:0] callout_talpha,
    input  wire [31:0] callout_grow,
    input  wire [15:0] res_width,
    input  wire [15:0] res_height,
    input  wire        res_active,
    input  wire [1:0]  adj_param_show,
    input  wire        adj_bar_visible,
    output wire        hs_out,
    output wire        vs_out,
    output wire        de_out,
    output wire [23:0] rgb_out
);
    // auto_play_en / fast_cycle_en 都在 SD 时钟域，这里各自两级同步到 video_clk。
    // 同步位按 {fast, auto} 原始对保存，再解码成 0/1/2 的选择子：
    //   手动 00 -> 0 / 自动跟读 01 -> 1 / 快速轮播 11 -> 2
    // 注意快速轮播时 auto_play_en 仍然是 1（KEY4 只是叠加 fast_cycle_en），
    // 所以解码**必须让 fast 位优先**，否则快速轮播会一直显示成“自动”。
    reg        auto_sync_meta;
    reg        auto_sync_video;
    reg        fast_sync_meta;
    reg        fast_sync_video;
    reg [1:0]  mode_last_sel;
    reg [26:0] mode_notice_timer;   // 75e6 需要 27 bit（原 1 s = 25e6 只要 25 bit）
    reg [1:0]  mode_notice_sel;
    // 原始对值 3 是“快速”，不是 2；这里统一解码，别在下面各处直接比较原始对。
    wire [1:0] mode_sync_sel = fast_sync_video ? 2'd2 :
                               auto_sync_video ? 2'd1 : 2'd0;
    wire       mode_notice_active = (mode_notice_timer != 27'd0);

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            auto_sync_meta   <= 1'b0;
            auto_sync_video  <= 1'b0;
            fast_sync_meta   <= 1'b0;
            fast_sync_video  <= 1'b0;
            mode_last_sel    <= 2'd0;
            mode_notice_timer <= 27'd0;
            mode_notice_sel   <= 2'd0;
        end else begin
            auto_sync_meta  <= auto_mode_async;
            auto_sync_video <= auto_sync_meta;
            fast_sync_meta  <= fast_mode_async;
            fast_sync_video <= fast_sync_meta;
            if (mode_sync_sel != mode_last_sel) begin
                mode_last_sel     <= mode_sync_sel;
                mode_notice_sel   <= mode_sync_sel;
                mode_notice_timer <= MODE_NOTICE_CYCLES;
            end else if (mode_notice_timer != 27'd0) begin
                mode_notice_timer <= mode_notice_timer - 27'd1;
            end
        end
    end

    localparam [9:0] FRAME_W = 10'd640;
    localparam [9:0] FRAME_H = 10'd480;
    localparam [9:0] SUB_X0  = 10'd192;
    localparam [9:0] SUB_Y0  = 10'd440;
    localparam [8:0] SUB_W   = 9'd256;
    localparam [9:0] LOGO_X0 = 10'd16;
    localparam [9:0] LOGO_Y0 = 10'd16;
    localparam [9:0] LOGO_W  = 10'd64;
    localparam [9:0] LOGO_H  = 10'd41;
    localparam [9:0] MODE_X0 = 10'd88;
    localparam [9:0] MODE_Y0 = 10'd16;
    localparam [9:0] RES_X0  = 10'd480;
    localparam [9:0] RES_Y0  = 10'd16;
    localparam [9:0] ADJ_X0  = 10'd570;
    localparam [9:0] ADJ_Y0  = 10'd232;
    localparam [14:0] NUM_GLYPH_BASE = 15'd20224;
    localparam [7:0]  NUM_GLYPH_STRIDE = 8'd130;

    // ---- 亮度/对比度名称标签（移植自 srcdian(1)，2026-10-23）----
    // 条本体占 x = 606..623、y = 152..328；标签右对齐到条的右边缘、画在条正下方：
    //   亮度   = 2 字（x 592..623）
    //   对比度 = 3 字（x 576..623）
    // 纵向 y = 336..351（距条底 8 px），与条、数值读数都不重叠。
    // 字形是 font_glyphs.mif 尾部追加的码 86..89（亮/度/对/比，14 px 2bit 掩码），
    // 走 {code, y, x} 的标准 256 布局 —— 和字幕同一套读法，不额外占 BRAM。
    localparam [9:0] NAM_XR = 10'd623;
    localparam [9:0] NAM_XL = 10'd576;
    localparam [9:0] NAM_Y0 = 10'd336;
    localparam [6:0] NAM_CODE_BASE = 7'd86;
    localparam [6:0] MODE_AUTO_FIRST_CODE = 7'd90; // 自
    localparam [6:0] MODE_SECOND_CODE     = 7'd91; // 动
    localparam [6:0] MODE_MANUAL_FIRST_CODE = 7'd92; // 手
    localparam [6:0] MODE_FAST_FIRST_CODE   = 7'd93; // 快
    localparam [6:0] MODE_FAST_SECOND_CODE  = 7'd94; // 速

    // ---- 右下角运行时长（系统开启时间）HH:MM:SS ----
    // 8 个 16 px 字格：h1 h0 : m1 m0 : s1 s0，占 x = 504..631、y = 456..471，
    // 右/下各留 8 px 不贴屏边。
    //   与字幕（x 192..447 / y 444..459）水平不重叠；
    //   与频谱面板（x 64..575 / y 370..440）垂直不重叠；
    //   与 callout 标签最大范围（y 393..416）也不重叠。
    // 数字复用 UI 数字字形（码 79..88）；**冒号不查表**，就是 2 个 2×2 白块，
    // 用像素坐标直接比较画出来 —— 给 ROM 加一项要重做 mif，而像素比较只花几个 LUT。
    localparam [9:0] TS_X0 = 10'd504;
    localparam [9:0] TS_Y0 = 10'd456;
    // video_clk 25 MHz -> 1 Hz。**改 video_clk 频率必须同步改这里**。
    localparam integer UPTIME_DIV = 25000000;

    // 运行时长：1 Hz 脉冲 + 6 位 BCD 递增（不走 double dabble，省一整条进位链）。
    // 24 小时回零；只在 1 Hz 上跳一次，组合深度对 25 MHz 毫无压力。
    reg [24:0] up_div;
    reg [3:0]  up_sec0, up_sec1;
    reg [3:0]  up_min0, up_min1;
    reg [3:0]  up_hour0, up_hour1;

    wire up_tick = (up_div == (UPTIME_DIV - 1));

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            up_div   <= 25'd0;
            up_sec0  <= 4'd0; up_sec1  <= 4'd0;
            up_min0  <= 4'd0; up_min1  <= 4'd0;
            up_hour0 <= 4'd0; up_hour1 <= 4'd0;
        end else if (up_tick) begin
            up_div <= 25'd0;
            if (up_sec0 != 4'd9) begin
                up_sec0 <= up_sec0 + 4'd1;
            end else begin
                up_sec0 <= 4'd0;
                if (up_sec1 != 4'd5) begin
                    up_sec1 <= up_sec1 + 4'd1;
                end else begin
                    up_sec1 <= 4'd0;
                    if (up_min0 != 4'd9) begin
                        up_min0 <= up_min0 + 4'd1;
                    end else begin
                        up_min0 <= 4'd0;
                        if (up_min1 != 4'd5) begin
                            up_min1 <= up_min1 + 4'd1;
                        end else begin
                            up_min1 <= 4'd0;
                            // 23:59:59 -> 00:00:00
                            if ((up_hour1 == 4'd2) && (up_hour0 == 4'd3)) begin
                                up_hour1 <= 4'd0;
                                up_hour0 <= 4'd0;
                            end else if (up_hour0 != 4'd9) begin
                                up_hour0 <= up_hour0 + 4'd1;
                            end else begin
                                up_hour0 <= 4'd0;
                                up_hour1 <= up_hour1 + 4'd1;
                            end
                        end
                    end
                end
            end
        end else begin
            up_div <= up_div + 25'd1;
        end
    end

    // Convert one 12-bit dimension at a time.  The shared double-dabble
    // datapath keeps the decimal readout off the pixel-critical path and
    // avoids two parallel width/height converters.
    localparam [1:0] RES_BCD_IDLE   = 2'd0;
    localparam [1:0] RES_BCD_WIDTH  = 2'd1;
    localparam [1:0] RES_BCD_HEIGHT = 2'd2;
    reg [1:0]  res_bcd_state;
    reg [11:0] res_width_latched;
    reg [11:0] res_height_latched;
    reg [15:0] res_bcd_shift;
    reg [3:0]  res_bcd_bit;
    reg [15:0] res_width_bcd;
    reg [15:0] res_height_bcd;
    reg [15:0] res_last_width;
    reg [15:0] res_last_height;
    reg        res_bcd_ready;
    wire       res_dimensions_changed = res_active &&
        ((res_width != res_last_width) || (res_height != res_last_height));

    function [15:0] bcd_shift_add3;
        input [15:0] bcd_in;
        input        bit_in;
        reg [15:0] adjusted;
        begin
            adjusted[3:0]   = (bcd_in[3:0]   >= 4'd5) ? (bcd_in[3:0]   + 4'd3) : bcd_in[3:0];
            adjusted[7:4]   = (bcd_in[7:4]   >= 4'd5) ? (bcd_in[7:4]   + 4'd3) : bcd_in[7:4];
            adjusted[11:8]  = (bcd_in[11:8]  >= 4'd5) ? (bcd_in[11:8]  + 4'd3) : bcd_in[11:8];
            adjusted[15:12] = (bcd_in[15:12] >= 4'd5) ? (bcd_in[15:12] + 4'd3) : bcd_in[15:12];
            bcd_shift_add3 = {adjusted[14:0], bit_in};
        end
    endfunction

    wire [15:0] res_bcd_shift_next = bcd_shift_add3(
        res_bcd_shift,
        (res_bcd_state == RES_BCD_WIDTH) ?
            res_width_latched[res_bcd_bit] : res_height_latched[res_bcd_bit]
    );

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            res_bcd_state      <= RES_BCD_IDLE;
            res_width_latched  <= 12'd0;
            res_height_latched <= 12'd0;
            res_bcd_shift      <= 16'd0;
            res_bcd_bit        <= 4'd0;
            res_width_bcd      <= 16'd0;
            res_height_bcd     <= 16'd0;
            res_last_width     <= 16'hFFFF;
            res_last_height    <= 16'hFFFF;
            res_bcd_ready      <= 1'b0;
        end else if ((res_bcd_state == RES_BCD_IDLE) && res_dimensions_changed) begin
            res_width_latched  <= res_width[11:0];
            res_height_latched <= res_height[11:0];
            res_last_width     <= res_width;
            res_last_height    <= res_height;
            res_bcd_shift      <= 16'd0;
            res_bcd_bit        <= 4'd11;
            res_bcd_state      <= RES_BCD_WIDTH;
        end else if ((res_bcd_state == RES_BCD_WIDTH) ||
                     (res_bcd_state == RES_BCD_HEIGHT)) begin
            res_bcd_shift <= res_bcd_shift_next;
            if (res_bcd_bit == 4'd0) begin
                res_bcd_bit <= 4'd11;
                if (res_bcd_state == RES_BCD_WIDTH) begin
                    res_width_bcd <= res_bcd_shift_next;
                    res_bcd_shift <= 16'd0;
                    res_bcd_state <= RES_BCD_HEIGHT;
                end else begin
                    res_height_bcd <= res_bcd_shift_next;
                    res_bcd_state  <= RES_BCD_IDLE;
                    res_bcd_ready  <= 1'b1;
                end
            end else begin
                res_bcd_bit <= res_bcd_bit - 4'd1;
            end
        end
    end

    // Pixel coordinates are counted only during active video, as before.
    // A small frame-boundary reveal, reusing existing subtitle glyphs.
    reg step_initialized;
    reg [1:0] step_track_latched;
    reg [5:0] step_reveal_width;
    reg step_vs_d;
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            step_initialized<=0;step_track_latched<=0;step_reveal_width<=0;step_vs_d<=0;
        end else begin
            step_vs_d<=vs_in;
            if (!display_valid) begin step_initialized<=0;step_reveal_width<=0;end
            else if (vs_in && !step_vs_d && !picker_plain && step_transition_idle) begin
                if (!step_initialized || step_track_latched!=step_track_id) begin
                    step_initialized<=1;step_track_latched<=step_track_id;step_reveal_width<=0;
                end else if (!step_pause && step_reveal_width<60)
                    step_reveal_width<=step_reveal_width+6'd4;
            end
        end
    end
    function [6:0] step_glyph_code;
        input [1:0] track,column;
        begin
            case(column)
                0:step_glyph_code=7'd1; // 第
                2:step_glyph_code=7'd3; // 步
                1:case(track)
                    0:step_glyph_code=7'd2;
                    1:step_glyph_code=7'd33;
                    2:step_glyph_code=7'd53;
                    default:step_glyph_code=7'd73;
                  endcase
                default:step_glyph_code=0;
            endcase
        end
    endfunction

    reg [9:0] pix_x;
    reg [9:0] pix_y;
    reg [9:0] x0;
    reg [9:0] y0;
    reg [9:0] x_d;
    reg [9:0] y_d;

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            pix_x <= 10'd0;
            pix_y <= 10'd0;
            x0    <= 10'd0;
            y0    <= 10'd0;
        end else begin
            x0 <= pix_x;
            y0 <= pix_y;
            if (de_in) begin
                if (pix_x == FRAME_W - 10'd1) begin
                    pix_x <= 10'd0;
                    if (pix_y == FRAME_H - 10'd1)
                        pix_y <= 10'd0;
                    else
                        pix_y <= pix_y + 10'd1;
                end else begin
                    pix_x <= pix_x + 10'd1;
                end
            end
        end
    end

    function [4:0] subtitle_char_count;
        input [4:0] id;
        begin
            case (id)
                5'd0:  subtitle_char_count = 5'd15;
                5'd1:  subtitle_char_count = 5'd8;
                5'd2:  subtitle_char_count = 5'd7;
                5'd3:  subtitle_char_count = 5'd8;
                5'd4:  subtitle_char_count = 5'd15;
                5'd5:  subtitle_char_count = 5'd11;
                5'd6:  subtitle_char_count = 5'd8;
                5'd7:  subtitle_char_count = 5'd13;
                5'd8:  subtitle_char_count = 5'd11;
                5'd9:  subtitle_char_count = 5'd7;
                5'd10: subtitle_char_count = 5'd12;
                5'd11: subtitle_char_count = 5'd7;
                5'd12: subtitle_char_count = 5'd11;
                default: subtitle_char_count = 5'd0;
            endcase
        end
    endfunction

    function [9:0] label_x0;
        input [2:0] id;
        begin
            case (id)
                3'd0: label_x0 = 10'd296;
                3'd1: label_x0 = 10'd506;
                3'd2: label_x0 = 10'd172;
                3'd3: label_x0 = 10'd41;
                3'd4: label_x0 = 10'd522;
                3'd5: label_x0 = 10'd19;
                3'd6: label_x0 = 10'd36;
                3'd7: label_x0 = 10'd449;
                default: label_x0 = 10'd0;
            endcase
        end
    endfunction

    function [9:0] label_y0;
        input [2:0] id;
        begin
            case (id)
                3'd0: label_y0 = 10'd83;
                3'd1: label_y0 = 10'd126;
                3'd2: label_y0 = 10'd146;
                3'd3: label_y0 = 10'd261;
                3'd4: label_y0 = 10'd393;
                3'd5: label_y0 = 10'd111;
                3'd6: label_y0 = 10'd251;
                3'd7: label_y0 = 10'd167;
                default: label_y0 = 10'd0;
            endcase
        end
    endfunction

    // The full leader/dot bounding regions are disjoint. They let one pixel
    // select a callout before the line/dot arithmetic and color mix stage.
    function callout_roi_hit;
        input [2:0] id;
        input [9:0] px;
        input [9:0] py;
        begin
            case (id)
                3'd0: callout_roi_hit = (px >= 10'd318) && (px < 10'd327) && (py >= 10'd101) && (py < 10'd131);
                3'd1: callout_roi_hit = (px >= 10'd514) && (px < 10'd523) && (py >= 10'd143) && (py < 10'd203);
                3'd2: callout_roi_hit = (px >= 10'd188) && (px < 10'd197) && (py >= 10'd163) && (py < 10'd225);
                3'd3: callout_roi_hit = (px >= 10'd78)  && (px < 10'd91)  && (py >= 10'd277) && (py < 10'd323);
                3'd4: callout_roi_hit = (px >= 10'd535) && (px < 10'd545) && (py >= 10'd355) && (py < 10'd396);
                3'd5: callout_roi_hit = (px >= 10'd73)  && (px < 10'd84)  && (py >= 10'd128) && (py < 10'd175);
                3'd6: callout_roi_hit = (px >= 10'd70)  && (px < 10'd117) && (py >= 10'd233) && (py < 10'd253);
                3'd7: callout_roi_hit = (px >= 10'd433) && (px < 10'd455) && (py >= 10'd183) && (py < 10'd217);
                default: callout_roi_hit = 1'b0;
            endcase
        end
    endfunction

    // packed segment: {axis, fix[9:0], near[9:0], far[9:0]}
    // axis=1 is horizontal; axis=0 is vertical.
    function [30:0] segment_a;
        input [2:0] id;
        begin
            case (id)
                3'd0: segment_a = {1'b0, 10'd322, 10'd126, 10'd105};
                3'd1: segment_a = {1'b0, 10'd518, 10'd198, 10'd147};
                3'd2: segment_a = {1'b0, 10'd192, 10'd220, 10'd167};
                3'd3: segment_a = {1'b0, 10'd85, 10'd318, 10'd282};
                3'd4: segment_a = {1'b0, 10'd540, 10'd360, 10'd390};
                3'd5: segment_a = {1'b0, 10'd78, 10'd170, 10'd132};
                3'd6: segment_a = {1'b1, 10'd238, 10'd112, 10'd75};
                3'd7: segment_a = {1'b0, 10'd438, 10'd212, 10'd188};
                default: segment_a = 31'd0;
            endcase
        end
    endfunction

    function [30:0] segment_b;
        input [2:0] id;
        begin
            case (id)
                3'd3: segment_b = {1'b1, 10'd282, 10'd85, 10'd79};
                3'd6: segment_b = {1'b0, 10'd75, 10'd238, 10'd248};
                3'd7: segment_b = {1'b1, 10'd188, 10'd438, 10'd448};
                default: segment_b = 31'd0;
            endcase
        end
    endfunction

    function [5:0] segment_a_length;
        input [2:0] id;
        begin
            case (id)
                3'd0: segment_a_length = 6'd21;
                3'd1: segment_a_length = 6'd51;
                3'd2: segment_a_length = 6'd53;
                3'd3: segment_a_length = 6'd36;
                3'd4: segment_a_length = 6'd30;
                3'd5: segment_a_length = 6'd38;
                3'd6: segment_a_length = 6'd37;
                3'd7: segment_a_length = 6'd24;
                default: segment_a_length = 6'd0;
            endcase
        end
    endfunction

    function [5:0] segment_b_length;
        input [2:0] id;
        begin
            case (id)
                3'd3: segment_b_length = 6'd6;
                3'd6: segment_b_length = 6'd10;
                3'd7: segment_b_length = 6'd10;
                default: segment_b_length = 6'd0;
            endcase
        end
    endfunction

    function [9:0] target_x;
        input [2:0] id;
        begin
            case (id)
                3'd0: target_x = 10'd322;
                3'd1: target_x = 10'd518;
                3'd2: target_x = 10'd192;
                3'd3: target_x = 10'd85;
                3'd4: target_x = 10'd540;
                3'd5: target_x = 10'd78;
                3'd6: target_x = 10'd112;
                3'd7: target_x = 10'd438;
                default: target_x = 10'd0;
            endcase
        end
    endfunction

    function [9:0] target_y;
        input [2:0] id;
        begin
            case (id)
                3'd0: target_y = 10'd126;
                3'd1: target_y = 10'd198;
                3'd2: target_y = 10'd220;
                3'd3: target_y = 10'd318;
                3'd4: target_y = 10'd360;
                3'd5: target_y = 10'd170;
                3'd6: target_y = 10'd238;
                3'd7: target_y = 10'd212;
                default: target_y = 10'd0;
            endcase
        end
    endfunction

    function seg_hit;
        input [30:0] seg;
        input [9:0] drawn;
        input [9:0] px;
        input [9:0] py;
        reg [9:0] fix, near_v, far_v, coord, lo, hi;
        reg axis, cross_hit;
        begin
            axis = seg[30];
            fix = seg[29:20];
            near_v = seg[19:10];
            far_v = seg[9:0];
            coord = axis ? px : py;
            cross_hit = axis ? ((py + 10'd1 >= fix) && (py <= fix + 10'd1))
                             : ((px + 10'd1 >= fix) && (px <= fix + 10'd1));
            if (drawn == 10'd0) begin
                seg_hit = 1'b0;
            end else if (far_v >= near_v) begin
                hi = near_v + drawn;
                seg_hit = cross_hit && (coord >= near_v) && (coord <= hi) && (coord <= far_v);
            end else begin
                lo = (near_v >= drawn) ? (near_v - drawn) : 10'd0;
                seg_hit = cross_hit && (coord <= near_v) && (coord >= lo) && (coord >= far_v);
            end
        end
    endfunction

    function dot_hit;
        input [9:0] px, py, cx, cy;
        reg [9:0] dx, dy;
        begin
            dx = (px >= cx) ? (px - cx) : (cx - px);
            dy = (py >= cy) ? (py - cy) : (cy - py);
            dot_hit = (dx <= 10'd4) && (dy <= 10'd4) && ((dx + dy) <= 10'd5);
        end
    endfunction

    function [7:0] blend_ch;
        input [7:0] bg;
        input       white_ink;
        input [2:0] alpha;
        reg [7:0] t;
        reg [9:0] p;
        begin
            if (alpha == 3'd0) begin
                blend_ch = bg;
            end else begin
                t = white_ink ? (8'd255 - bg) : bg;
                case (alpha)
                    3'd1: p = {2'b00, t} >> 2;
                    3'd2: p = {2'b00, t} >> 1;
                    3'd3: p = {2'b00, t} - ({2'b00, t} >> 2);
                    default: p = {2'b00, t};
                endcase
                blend_ch = white_ink ? (bg + p[7:0]) : (bg - p[7:0]);
            end
        end
    endfunction

    reg [7:0] roi_hits;
    reg [2:0] roi_sel;
    reg       roi_any;
    integer   ri;
    always @* begin
        roi_hits = 8'd0;
        roi_sel = 3'd0;
        roi_any = 1'b0;
        for (ri = 0; ri < 8; ri = ri + 1) begin
            roi_hits[ri] = callout_on[ri] && de_in &&
                           callout_roi_hit(ri[2:0], pix_x, pix_y);
        end
        // ROI bounds do not overlap. This priority is a deterministic fallback.
        for (ri = 7; ri >= 0; ri = ri - 1) begin
            if (roi_hits[ri]) begin
                roi_any = 1'b1;
                roi_sel = ri[2:0];
            end
        end
    end

    wire [5:0] len_a_sel = segment_a_length(roi_sel);
    wire [5:0] len_b_sel = segment_b_length(roi_sel);
    wire [6:0] len_total_sel = {1'b0, len_a_sel} + {1'b0, len_b_sel};
    wire [3:0] grow_sel = callout_grow[roi_sel*4 +: 4];
    wire [10:0] grow_product = grow_sel * len_total_sel;
    wire [9:0] draw_total = {2'b00, grow_product[10:3]};
    wire [9:0] draw_a = (draw_total >= {4'd0, len_a_sel}) ? {4'd0, len_a_sel} : draw_total;
    wire [9:0] draw_b = (draw_total > {4'd0, len_a_sel}) ? (draw_total - {4'd0, len_a_sel}) : 10'd0;
    wire [30:0] seg_a_sel = segment_a(roi_sel);
    wire [30:0] seg_b_sel = segment_b(roi_sel);
    wire line_hit = roi_any &&
                    (seg_hit(seg_a_sel, draw_a, pix_x, pix_y) ||
                     seg_hit(seg_b_sel, draw_b, pix_x, pix_y));
    wire dot_visible = roi_any && dot_hit(pix_x, pix_y, target_x(roi_sel), target_y(roi_sel));
    wire [2:0] line_alpha = roi_any ? callout_alpha[roi_sel*3 +: 3] : 3'd0;

    // One callout label is read per pixel. The approved label canvases do not overlap.
    reg [7:0] label_hits;
    reg [2:0] label_sel;
    reg       label_any;
    integer   li;
    always @* begin
        label_hits = 8'd0;
        label_sel = 3'd0;
        label_any = 1'b0;
        for (li = 0; li < 8; li = li + 1) begin
            label_hits[li] = callout_on[li] && de_in && display_valid &&
                             (pix_x >= label_x0(li[2:0])) &&
                             (pix_x < label_x0(li[2:0]) + 10'd96) &&
                             (pix_y >= label_y0(li[2:0])) &&
                             (pix_y < label_y0(li[2:0]) + 10'd24);
        end
        for (li = 7; li >= 0; li = li - 1) begin
            if (label_hits[li]) begin
                label_sel = li[2:0];
                label_any = 1'b1;
            end
        end
    end

    wire [9:0] label_rel_x = pix_x - label_x0(label_sel) - 10'd1;
    wire [9:0] label_rel_y = pix_y - label_y0(label_sel) - 10'd1;
    wire label_glyph_area = label_any &&
                            (pix_x >= label_x0(label_sel) + 10'd1) &&
                            (pix_x <  label_x0(label_sel) + 10'd96) &&
                            (pix_y >= label_y0(label_sel) + 10'd1) &&
                            (pix_y <  label_y0(label_sel) + 10'd17);
    wire [2:0] label_col = label_rel_x[6:4];
    wire [8:0] label_code_addr = 9'd208 + {3'd0, label_sel, 3'b000} + {6'd0, label_col};
    wire [2:0] label_alpha_in = label_any ? callout_talpha[label_sel*3 +: 3] : 3'd0;

    wire [3:0] rw3 = res_width_bcd[15:12];
    wire [3:0] rw2 = res_width_bcd[11:8];
    wire [3:0] rw1 = res_width_bcd[7:4];
    wire [3:0] rw0 = res_width_bcd[3:0];
    wire [3:0] rh3 = res_height_bcd[15:12];
    wire [3:0] rh2 = res_height_bcd[11:8];
    wire [3:0] rh1 = res_height_bcd[7:4];
    wire [3:0] rh0 = res_height_bcd[3:0];
    wire [3:0] rw_start = (rw3 != 4'd0) ? 4'd0 :
                          (rw2 != 4'd0) ? 4'd1 :
                          (rw1 != 4'd0) ? 4'd2 : 4'd3;
    wire [3:0] rh_start = (rh3 != 4'd0) ? 4'd0 :
                          (rh2 != 4'd0) ? 4'd1 :
                          (rh1 != 4'd0) ? 4'd2 : 4'd3;
    wire [3:0] res_width_count=4-rw_start;
    wire [3:0] res_digit_count=9-rw_start-rh_start;
    wire [7:0] res_total_width=8'd61+res_digit_count*8'd11;
    wire [9:0] res_left=10'd624-res_total_width;
    wire [9:0] res_rel_x=pix_x-res_left;
    wire [9:0] res_num_x=res_rel_x-10'd62;
    // Fixed comparators avoid a runtime divider for eleven-pixel cells.
    wire [3:0] res_cell=res_num_x<11?0:res_num_x<22?1:res_num_x<33?2:
      res_num_x<44?3:res_num_x<55?4:res_num_x<66?5:res_num_x<77?6:res_num_x<88?7:8;
    wire [3:0] res_num_dx=res_num_x-res_cell*4'd11;
    wire [3:0] res_w_pos=res_cell+rw_start;
    wire [3:0] res_h_pos=res_cell-res_width_count-1+rh_start;
    wire res_w_show=res_cell<res_width_count;
    wire res_is_x=res_cell==res_width_count;
    wire [3:0] res_w_digit=res_w_pos==0?rw3:res_w_pos==1?rw2:res_w_pos==2?rw1:rw0;
    wire [3:0] res_h_digit=res_h_pos==0?rh3:res_h_pos==1?rh2:res_h_pos==2?rh1:rh0;
    wire [3:0] res_sel=res_is_x?4'd10:res_w_show?res_w_digit:res_h_digit;
    wire res_area=ENABLE_RES_READOUT && de_in && display_valid && res_active && res_bcd_ready &&
      pix_x>=res_left && pix_x<624 && pix_y>=RES_Y0 && pix_y<RES_Y0+16;
    wire res_prefix_area=res_area && res_rel_x<56;
    wire res_colon_area=res_area && res_rel_x>=56 && res_rel_x<60;
    wire [1:0] res_prefix_cell=res_rel_x<14?0:res_rel_x<28?1:res_rel_x<42?2:3;
    wire [3:0] res_prefix_x=res_rel_x-res_prefix_cell*4'd14;
    wire res_glyph_area=res_area && res_rel_x>=62 && res_num_dx<10;

    wire signed [4:0] adj_level = (adj_param_show == 2'd1) ?
                                  brightness_level : contrast_level;
    wire [3:0] adj_mag = adj_level[4] ? (4'd0 - adj_level[3:0]) : adj_level[3:0];
    wire adj_neg = adj_level[4];
    wire adj_zero = (adj_level == 5'sd0);
    wire [23:0] adj_color = (adj_param_show == 2'd1) ? 24'hFFD23F : 24'hC080FF;
    wire [9:0] adj_rel_x = {1'b0, pix_x} - {1'b0, ADJ_X0};
    wire [3:0] adj_cell = adj_rel_x[7:4];
    wire adj_sign_blank = (adj_cell == 4'd0) && adj_zero;
    wire [3:0] adj_sel = (adj_cell == 4'd0) ? (adj_neg ? 4'd12 : 4'd11) : adj_mag;
    wire adj_glyph_area = ENABLE_ADJ_READOUT && de_in && display_valid && adj_bar_visible &&
                          (pix_x >= ADJ_X0) && (pix_x < ADJ_X0 + 10'd32) &&
                          (pix_y >= ADJ_Y0) && (pix_y < ADJ_Y0 + 10'd16) &&
                          !adj_sign_blank;

    // ---- 亮度/对比度名称标签几何 ----
    // 右对齐到条的右边缘：nam_dx = 0 是最右一列，越大越往左；[5:4] 就是格号。
    // 亮度（2 字）：格 0 = 度、格 1 = 亮，格 2 空白
    // 对比度（3 字）：格 0 = 度、格 1 = 比、格 2 = 对
    // 选择子直接等于"字形码 - 86"：0 = 亮、1 = 度、2 = 对、3 = 比。
    wire [9:0] nam_dx   = (pix_x <= NAM_XR) ? (NAM_XR - pix_x) : 10'd63;
    wire [1:0] nam_cell = nam_dx[5:4];
    wire [1:0] nam_sel  = (nam_cell == 2'd0) ? 2'd1 :
                          (nam_cell == 2'd1) ? ((adj_param_show == 2'd1) ? 2'd0 : 2'd3) :
                                               2'd2;
    wire nam_blank = (adj_param_show == 2'd1) && (nam_cell >= 2'd2);
    wire nam_area = ENABLE_ADJ_READOUT && de_in && display_valid && adj_bar_visible &&
                    (pix_x >= NAM_XL) && (pix_x <= NAM_XR) &&
                    (pix_y >= NAM_Y0) && (pix_y < NAM_Y0 + 10'd16) &&
                    !nam_blank;

    // Two 16x16 mode glyphs beside the Logo. The captured mode remains stable
    // while the notice timer is active; expiry hides only the text.
    wire [9:0] mode_rel_x = {1'b0, pix_x} - {1'b0, MODE_X0};
    wire mode_notice_glyph_area = mode_notice_active && de_in && display_valid &&
                                  (pix_x >= MODE_X0) && (pix_x < MODE_X0 + 10'd32) &&
                                  (pix_y >= MODE_Y0) && (pix_y < MODE_Y0 + 10'd16);
    wire [6:0] mode_notice_glyph_code = (mode_rel_x < 10'd16) ?
            ((mode_notice_sel == 2'd1) ? MODE_AUTO_FIRST_CODE :
             (mode_notice_sel == 2'd2) ? MODE_FAST_FIRST_CODE :
                                         MODE_MANUAL_FIRST_CODE) :
            ((mode_notice_sel == 2'd2) ? MODE_FAST_SECOND_CODE :
                                         MODE_SECOND_CODE);

    // ---- 右下角运行时长几何：8 格 = h1 h0 : m1 m0 : s1 s0 ----
    wire [9:0] ts_rel_x = {1'b0, pix_x} - TS_X0;
    wire [2:0] ts_cell  = ts_rel_x[7:4];        // 0..7
    wire       ts_colon = (ts_cell == 3'd2) || (ts_cell == 3'd5);
    wire [3:0] ts_dig   = (ts_cell == 3'd0) ? up_hour1 :
                          (ts_cell == 3'd1) ? up_hour0 :
                          (ts_cell == 3'd3) ? up_min1  :
                          (ts_cell == 3'd4) ? up_min0  :
                          (ts_cell == 3'd6) ? up_sec1  : up_sec0;
    wire [3:0] ts_gx = ts_rel_x[3:0];
    wire [3:0] ts_gy = pix_y - TS_Y0;
    // 冒号：格内 x = 7..8，y = 5..6 与 y = 10..11 各一个 2×2 白块。
    wire ts_dot = ts_colon && ((ts_gx == 4'd7) || (ts_gx == 4'd8)) &&
                  (((ts_gy == 4'd5) || (ts_gy == 4'd6)) ||
                   ((ts_gy == 4'd10) || (ts_gy == 4'd11)));
    wire ts_area = de_in && display_valid &&
                   (pix_x >= TS_X0) && (pix_x < TS_X0 + 10'd128) &&
                   (pix_y >= TS_Y0) && (pix_y < TS_Y0 + 10'd16);

    wire [9:0] sub_rel_x = {1'b0, pix_x} - {1'b0, SUB_X0};
    wire [4:0] sub_chars = subtitle_char_count(subtitle_id);
    wire [8:0] sub_width = {sub_chars, 4'b0000};
    wire [8:0] sub_start_x = (SUB_W - sub_width) >> 1;
    wire [8:0] sub_text_x = sub_rel_x[8:0] - sub_start_x;
    wire subtitle_glyph_area = de_in && display_valid && subtitle_active &&
                               (pix_x >= SUB_X0) && (pix_x < SUB_X0 + SUB_W) &&
                               (pix_y >= SUB_Y0 + 10'd4) && (pix_y < SUB_Y0 + 10'd20) &&
                               (sub_rel_x[8:0] >= sub_start_x) &&
                               (sub_rel_x[8:0] < (sub_start_x + sub_width));
    wire [3:0] sub_col = sub_text_x[7:4];
    wire [8:0] subtitle_code_addr = {subtitle_id, sub_col};

    wire step_area = display_valid && step_initialized && step_transition_idle &&
                     !picker_plain && de_in && (pix_x>=16) &&
                     (pix_x < (10'd16+{4'd0,step_reveal_width})) &&
                     (pix_y>=64) && (pix_y<84);
    wire [9:0] grid_x=pix_x>=320?pix_x-320:pix_x;
    wire [9:0] grid_y=pix_y>=240?pix_y-240:pix_y;
    wire grid_step_area=picker_grid_visible && de_in && grid_x>=8 && grid_x<56 && grid_y>=8 && grid_y<24;
    wire [9:0] step_rel_x = grid_step_area?grid_x-10'd8:pix_x-10'd22;
    wire step_glyph_area=step_area && pix_x>=22 && pix_x<70 && pix_y>=66 && pix_y<82;
    wire [6:0] step_code=step_glyph_code(grid_step_area?{pix_y>=240,pix_x>=320}:step_track_latched,step_rel_x[5:4]);
    reg step_mode0;
    reg [6:0] step_code0;
    reg [8:0] text_code_addr;
    reg [3:0] font_x;
    reg [3:0] font_y;
    reg       subtitle_mode0;
    reg [1:0] subtitle_level0;
    reg       label_mode0;
    reg [2:0] label_alpha0;
    reg       line_mode0;
    reg [2:0] line_alpha0;
    reg       res_mode0;
    reg       adj_mode0;
    reg [23:0] adj_color0;
    reg       nam_mode0;
    reg [1:0] nam_sel0;
    reg       mode_notice_mode0;
    reg [6:0] mode_notice_code0;
    reg       ts_mode0;
    reg       ts_colon0;
    reg       ts_dot0;
    reg       special_mode;
    reg [3:0] special_sel;
    always @* begin
        text_code_addr = 9'd0;
        font_x = 4'd0;
        font_y = 4'd0;
        subtitle_mode0 = 1'b0;
        subtitle_level0 = subtitle_level;
        label_mode0 = 1'b0;
        label_alpha0 = label_alpha_in;
        res_mode0 = 1'b0;
        adj_mode0 = 1'b0;
        adj_color0 = adj_color;
        nam_mode0 = 1'b0;
        nam_sel0 = 2'd0;
        mode_notice_mode0 = 1'b0;
        mode_notice_code0 = MODE_AUTO_FIRST_CODE;
        ts_mode0 = 1'b0;
        ts_colon0 = 1'b0;
        ts_dot0 = 1'b0;
        step_mode0=1'b0;step_code0=7'd0;
        special_mode = 1'b0;
        special_sel = 4'd0;

        if(grid_step_area) begin
            step_mode0=1;step_code0=step_code;font_x=step_rel_x[3:0];font_y=grid_y-8;
        end else if(res_prefix_area && !picker_plain) begin
            step_mode0=1;step_code0=7'd95+res_prefix_cell;font_x=res_prefix_x;font_y=pix_y-RES_Y0;
            res_mode0=1;
        end else if (adj_glyph_area) begin
            special_mode = 1'b1;
            special_sel = adj_sel;
            font_x = adj_rel_x[3:0];
            font_y = pix_y - ADJ_Y0;
            adj_mode0 = 1'b1;
        end else if (res_glyph_area) begin
            special_mode = 1'b1;
            special_sel = res_sel;
            font_x = res_num_dx;
            font_y = pix_y - RES_Y0;
            res_mode0 = 1'b1;
        end else if (subtitle_glyph_area) begin
            text_code_addr = subtitle_code_addr;
            font_x = sub_text_x[3:0];
            font_y = pix_y - (SUB_Y0 + 10'd4);
            subtitle_mode0 = 1'b1;
        end else if (label_glyph_area) begin
            text_code_addr = label_code_addr;
            font_x = label_rel_x[3:0];
            font_y = label_rel_y[3:0];
            label_mode0 = 1'b1;
        end else if (nam_area) begin
            // 亮度/对比度名称：走中文字形的标准 {code, y, x} 布局，
            // 所以**不置 special_mode**（那条路会进 UI 数字的 130 像素紧凑排布）。
            nam_mode0 = 1'b1;
            nam_sel0  = nam_sel;
            // nam_dx 是从右边缘往左数的列号（0 = 最右一列），
            // 而字形本身是正写的，所以列号要翻回来：15 - nam_dx[3:0]。
            font_x = 4'd15 - nam_dx[3:0];
            font_y = pix_y - NAM_Y0;
        end else if (mode_notice_glyph_area) begin
            mode_notice_mode0 = 1'b1;
            mode_notice_code0 = mode_notice_glyph_code;
            font_x = mode_rel_x[3:0];
            font_y = pix_y - MODE_Y0;
        end else if (step_glyph_area && !line_hit && !dot_visible) begin
            step_mode0=1'b1;step_code0=step_code;
            font_x=step_rel_x[3:0];font_y=pix_y-10'd66;
        end else if (ts_area) begin
            // 右下角运行时长：优先级最低（它只是个角标，谁压它都行）。
            // 数字格走 UI 数字字形；冒号格也占 special_sel（值随便，
            // 合成处由 ts_colon1 直接盖掉），这样不用为冒号再开一条查表路径。
            special_mode = 1'b1;
            special_sel  = ts_dig;
            font_x = ts_gx;
            font_y = ts_gy;
            ts_mode0  = 1'b1;
            ts_colon0 = ts_colon;
            ts_dot0   = ts_dot;
        end

        // Apply display_valid after the ROI/growth/line calculation so its
        // control path does not pass through the full callout geometry chain.
        line_mode0 = display_valid && (line_hit || dot_visible);
        line_alpha0 = line_alpha;
    end

    wire [6:0] rom_char_code;
    osd_text_char_rom u_text_char_rom (
        .clka  (video_clk),
        .addra (text_code_addr),
        .doa   (rom_char_code)
    );

    reg [3:0] font_x0;
    reg [3:0] font_y0;
    reg        special_mode_d;
    reg res_mode_d;
    reg [3:0]  special_sel_d;
    reg        nam_mode_d;
    reg [1:0]  nam_sel_d;
    reg        mode_notice_mode_d;
    reg [6:0]  mode_notice_code_d;
    // 中文字形（码 86..89 = 亮/度/对/比）同样旁路码表，直接由选择子算码。
    // nam_mode_d / nam_sel_d 与 special_mode_d 同为 1 拍延迟，和 rom_char_code 对齐。
    reg step_mode_d;
    reg [6:0] step_code_d;
    wire [6:0] text_char_code = step_mode_d ? step_code_d : mode_notice_mode_d ? mode_notice_code_d :
                                nam_mode_d ?
                                (NAM_CODE_BASE + {5'd0, nam_sel_d}) :
                                special_mode_d ?
                                (7'd79 + {3'd0, special_sel_d}) : rom_char_code;

    function [3:0] numeric_x_min;
        input [3:0] idx;
        begin
            case (idx)
                4'd0: numeric_x_min = 4'd4;
                4'd1: numeric_x_min = 4'd5;
                4'd2: numeric_x_min = 4'd4;
                4'd3: numeric_x_min = 4'd4;
                4'd4: numeric_x_min = 4'd3;
                4'd5: numeric_x_min = 4'd4;
                4'd6: numeric_x_min = 4'd4;
                4'd7: numeric_x_min = 4'd3;
                4'd8: numeric_x_min = 4'd4;
                4'd9: numeric_x_min = 4'd4;
                4'd10: numeric_x_min = 4'd3;
                4'd11: numeric_x_min = 4'd3;
                4'd12: numeric_x_min = 4'd5;
                default: numeric_x_min = 4'd0;
            endcase
        end
    endfunction

    function [3:0] numeric_y_min;
        input [3:0] idx;
        begin
            case (idx)
                4'd0, 4'd1, 4'd2, 4'd3, 4'd4,
                4'd5, 4'd6, 4'd7, 4'd8, 4'd9: numeric_y_min = 4'd1;
                4'd10, 4'd11: numeric_y_min = 4'd3;
                4'd12: numeric_y_min = 4'd6;
                default: numeric_y_min = 4'd0;
            endcase
        end
    endfunction

    function [3:0] numeric_width;
        input [3:0] idx;
        begin
            case (idx)
                4'd0, 4'd2, 4'd5, 4'd6, 4'd8, 4'd9: numeric_width = 4'd8;
                4'd1, 4'd12: numeric_width = 4'd6;
                4'd3: numeric_width = 4'd7;
                4'd4: numeric_width = 4'd10;
                4'd7: numeric_width = 4'd9;
                4'd10: numeric_width = 4'd9;
                4'd11: numeric_width = 4'd9;
                default: numeric_width = 4'd0;
            endcase
        end
    endfunction

    function [3:0] numeric_height;
        input [3:0] idx;
        begin
            case (idx)
                4'd0, 4'd1, 4'd2, 4'd3, 4'd4,
                4'd5, 4'd6, 4'd7, 4'd8, 4'd9: numeric_height = 4'd13;
                4'd10: numeric_height = 4'd10;
                4'd11: numeric_height = 4'd9;
                4'd12: numeric_height = 4'd3;
                default: numeric_height = 4'd0;
            endcase
        end
    endfunction

    wire [3:0] numeric_x0 = numeric_x_min(special_sel_d);
    wire [3:0] numeric_y0 = numeric_y_min(special_sel_d);
    wire [3:0] numeric_dx = res_mode_d ? font_x0 : font_x0 - numeric_x0;
    wire [3:0] numeric_dy = res_mode_d ? (font_y0-(special_sel_d==10?4'd3:4'd1)) : font_y0 - numeric_y0;
    wire numeric_inside = res_mode_d ? (font_x0<10 && numeric_dy<13) : (font_x0 >= numeric_x0) &&
                          (numeric_dx < numeric_width(special_sel_d)) &&
                          (font_y0 >= numeric_y0) &&
                          (numeric_dy < numeric_height(special_sel_d));
    wire [11:0] numeric_slot_offset = {8'd0, special_sel_d} * 12'd130;
    wire [6:0] numeric_row_offset = ({3'd0, numeric_dy} << 3) +
                                    ({3'd0, numeric_dy} << 1);
    wire [11:0] numeric_pixel_offset = numeric_slot_offset +
                                       {5'd0, numeric_row_offset} +
                                       {8'd0, numeric_dx};
    wire [14:0] numeric_glyph_addr = NUM_GLYPH_BASE + numeric_pixel_offset;
    wire [14:0] glyph_addr = special_mode_d ?
                             (numeric_inside ? numeric_glyph_addr : 15'd0) :
                             {text_char_code, font_y0, font_x0};
    wire [1:0] glyph_mask;
    osd_font_glyph_rom u_font_glyph_rom (
        .clka  (video_clk),
        .addra (glyph_addr),
        .doa   (glyph_mask)
    );

    reg [23:0] rgb0;
    reg [23:0] rgb1;
    reg hs0, vs0, de0;
    reg hs1, vs1, de1;
    reg subtitle_mode_q0;
    reg [1:0] subtitle_level_q0;
    reg label_mode_q0;
    reg [2:0] label_alpha_q0;
    reg line_mode_q0;
    reg [2:0] line_alpha_q0;
    reg res_mode_q0;
    reg adj_mode_q0;
    reg [23:0] adj_color_q0;
    reg nam_mode_q0;
    reg mode_notice_q0;
    reg ts_mode_q0;
    reg ts_colon_q0;
    reg ts_dot_q0;
    reg subtitle_mode1;
    reg [1:0] subtitle_level1;
    reg label_mode1;
    reg [2:0] label_alpha1;
    reg line_mode1;
    reg [2:0] line_alpha1;
    reg res_mode1;
    reg adj_mode1;
    reg [23:0] adj_color1;
    reg nam_mode1;
    reg mode_notice_mode1;
    reg ts_mode1;
    reg ts_colon1;
    reg ts_dot1;
    reg step_text_q0,step_text1;
    reg plain0,plain1;
    reg res_colon0,res_colon1,res_dot0,res_dot1;
    reg signed [4:0] brightness0;
    reg signed [4:0] contrast0;
    reg signed [4:0] brightness1;
    reg signed [4:0] contrast1;
    reg logo_area_q0;

    // The logo ROM is read from the same delayed coordinates as rgb1, so
    // its palette index and coverage bit align with the existing two-stage
    // pixel path. White/background pixels use palette index 0 (transparent).
    wire logo_area0 = de0 && display_valid &&
                      (x0 >= LOGO_X0) && (x0 < LOGO_X0 + LOGO_W) &&
                      (y0 >= LOGO_Y0) && (y0 < LOGO_Y0 + LOGO_H);
    wire [5:0] logo_x = x0 - LOGO_X0;
    wire [5:0] logo_y = y0 - LOGO_Y0;
    wire [11:0] logo_addr = logo_area0 ? {logo_y, logo_x} : 12'd0;
    wire [1:0] logo_index;
    osd_logo_index_rom u_osd_logo_index_rom (
        .clka  (video_clk),
        .addra (logo_addr),
        .doa   (logo_index)
    );

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            rgb0 <= 24'd0;
            rgb1 <= 24'd0;
            hs0 <= 1'b0; vs0 <= 1'b0; de0 <= 1'b0;
            hs1 <= 1'b0; vs1 <= 1'b0; de1 <= 1'b0;
            subtitle_mode_q0 <= 1'b0;
            subtitle_level_q0 <= 2'd0;
            label_mode_q0 <= 1'b0;
            label_alpha_q0 <= 3'd0;
            line_mode_q0 <= 1'b0;
            line_alpha_q0 <= 3'd0;
            res_mode_q0 <= 1'b0;
            adj_mode_q0 <= 1'b0;
            adj_color_q0 <= 24'd0;
            nam_mode_q0 <= 1'b0;
            mode_notice_q0 <= 1'b0;
            ts_mode_q0 <= 1'b0;
            ts_colon_q0 <= 1'b0;
            ts_dot_q0 <= 1'b0;
            subtitle_mode1 <= 1'b0;
            subtitle_level1 <= 2'd0;
            label_mode1 <= 1'b0;
            label_alpha1 <= 3'd0;
            line_mode1 <= 1'b0;
            line_alpha1 <= 3'd0;
            res_mode1 <= 1'b0;
            adj_mode1 <= 1'b0;
            adj_color1 <= 24'd0;
            nam_mode1 <= 1'b0;
            mode_notice_mode1 <= 1'b0;
            ts_mode1 <= 1'b0;
            ts_colon1 <= 1'b0;
            ts_dot1 <= 1'b0;
            x_d <= 10'd0;
            y_d <= 10'd0;
            font_x0 <= 4'd0; font_y0 <= 4'd0;
            special_mode_d <= 1'b0;
            special_sel_d <= 4'd0;
            nam_mode_d <= 1'b0;
            nam_sel_d <= 2'd0;
            mode_notice_mode_d <= 1'b0;
            mode_notice_code_d <= MODE_AUTO_FIRST_CODE;
            step_text_q0<=0;step_text1<=0;step_mode_d<=0;step_code_d<=0;
            plain0<=0;plain1<=0;res_colon0<=0;res_colon1<=0;res_dot0<=0;res_dot1<=0;res_mode_d<=0;
            brightness0 <= 5'sd0; contrast0 <= 5'sd0;
            brightness1 <= 5'sd0; contrast1 <= 5'sd0;
            logo_area_q0 <= 1'b0;
        end else begin
            step_text_q0<=step_mode0 && !res_mode0;
            step_text1<=step_text_q0;
            step_mode_d<=step_mode0;step_code_d<=step_code0;
            plain0<=picker_plain;plain1<=plain0;
            res_colon0<=res_colon_area && res_rel_x<59 &&
              ((pix_y>=19&&pix_y<23)||(pix_y>=24&&pix_y<28));res_colon1<=res_colon0;
            res_dot0<=res_rel_x==57 && ((pix_y>=20&&pix_y<22)||(pix_y>=25&&pix_y<27));res_dot1<=res_dot0;
            rgb0 <= rgb_in;
            hs0 <= hs_in; vs0 <= vs_in; de0 <= de_in;
            subtitle_mode_q0 <= subtitle_mode0;
            subtitle_level_q0 <= subtitle_level0;
            label_mode_q0 <= label_mode0;
            label_alpha_q0 <= label_alpha0;
            line_mode_q0 <= line_mode0;
            line_alpha_q0 <= line_alpha0;
            res_mode_q0 <= res_mode0;
            adj_mode_q0 <= adj_mode0;
            adj_color_q0 <= adj_color0;
            nam_mode_q0 <= nam_mode0;
            mode_notice_q0 <= mode_notice_mode0;
            ts_mode_q0 <= ts_mode0;
            ts_colon_q0 <= ts_colon0;
            ts_dot_q0 <= ts_dot0;
            font_x0 <= font_x;
            font_y0 <= font_y;
            res_mode_d<=res_mode0;
            special_mode_d <= special_mode;
            special_sel_d <= special_sel;
            nam_mode_d <= nam_mode0;
            nam_sel_d <= nam_sel0;
            mode_notice_mode_d <= mode_notice_mode0;
            mode_notice_code_d <= mode_notice_code0;
            brightness0 <= brightness_level;
            contrast0 <= contrast_level;
            logo_area_q0 <= logo_area0;

            rgb1 <= rgb0;
            hs1 <= hs0; vs1 <= vs0; de1 <= de0;
            x_d <= x0; y_d <= y0;
            subtitle_mode1 <= subtitle_mode_q0;
            subtitle_level1 <= subtitle_level_q0;
            label_mode1 <= label_mode_q0;
            label_alpha1 <= label_alpha_q0;
            line_mode1 <= line_mode_q0;
            line_alpha1 <= line_alpha_q0;
            res_mode1 <= res_mode_q0;
            adj_mode1 <= adj_mode_q0;
            adj_color1 <= adj_color_q0;
            nam_mode1 <= nam_mode_q0;
            mode_notice_mode1 <= mode_notice_q0;
            ts_mode1 <= ts_mode_q0;
            ts_colon1 <= ts_colon_q0;
            ts_dot1 <= ts_dot_q0;
            x_d <= x0;
            y_d <= y0;
            brightness1 <= brightness0;
            contrast1 <= contrast0;
        end
    end

    reg [23:0] rgb_content;
    reg        overlay_active;
    reg        overlay_white;
    reg [2:0]  overlay_alpha;
    always @* begin
        rgb_content = rgb1;
        overlay_active = 1'b0;
        overlay_white = 1'b1;
        overlay_alpha = 3'd0;
        if (adj_mode1) begin
            if (glyph_mask == 2'd1)
                rgb_content = 24'h000000;
            else if (glyph_mask == 2'd2)
                rgb_content = adj_color1;
        end else if (res_mode1) begin
            if (glyph_mask == 2'd1)
                rgb_content = 24'h000000;
            else if (glyph_mask == 2'd2)
                rgb_content = 24'hFFFFFF;
        end else begin
            if (label_mode1 && (glyph_mask != 2'd0) && (label_alpha1 != 3'd0)) begin
                overlay_active = 1'b1;
                overlay_white = (glyph_mask == 2'd2);
                overlay_alpha = label_alpha1;
            end else if (line_mode1 && (line_alpha1 != 3'd0)) begin
                overlay_active = 1'b1;
                overlay_white = 1'b1;
                overlay_alpha = line_alpha1;
            end

            // Verified geometry/bitmap audit: no callout line or target dot
            // intersects any nontransparent label glyph pixel. Thus one mixer
            // can render either the label or the line/dot with identical pixels.
            if (overlay_active) begin
                rgb_content[7:0] = blend_ch(rgb1[7:0], overlay_white, overlay_alpha);
                rgb_content[15:8] = blend_ch(rgb1[15:8], overlay_white, overlay_alpha);
                rgb_content[23:16] = blend_ch(rgb1[23:16], overlay_white, overlay_alpha);
            end

            if (subtitle_mode1 && (glyph_mask != 2'd0)) begin
                if (glyph_mask == 2'd1)
                    rgb_content = 24'h000000;
                else if (subtitle_level1 == 2'd1)
                    rgb_content = 24'hA0A0A0;
                else
                    rgb_content = 24'hFFFFFF;
            end
        end
        // Prefix, colon and dimensions share the existing picture adjustment.
        if(res_colon1)rgb_content=res_dot1?24'hFFFFFF:24'h000000;
    end

    wire [23:0] rgb_adjusted;
    picture_adjust u_picture_adjust (
        .rgb_in            (plain1?rgb1:rgb_content),
        .brightness_level  (brightness1),
        .contrast_level    (contrast1),
        .rgb_out           (rgb_adjusted)
    );

    // Keep the main-v8 ordering: the Logo is composited after picture
    // adjustment and does not change with the brightness/contrast controls.
    // 白字黑描边通路（右下运行时长）的"落笔 / 描边"判定：并行算好再进合成，
    // 合成处只留一级 2:1。冒号格（ts_colon1）不吃 glyph_mask —— 那格没查到字形，
    // 由 ts_dot1 直接决定（像素比较画出来的 2×2 白块）。
    wire ts_paint1 = ts_mode1 && (ts_colon1 ? ts_dot1 : (glyph_mask != 2'd0));
    wire ts_dark1  = ts_mode1 && !ts_colon1 && (glyph_mask == 2'd1);

    reg [23:0] rgb_with_logo;
    always @* begin
        rgb_with_logo = rgb_adjusted;
        if(step_text1 && glyph_mask!=0) rgb_with_logo=glyph_mask==1?24'h000000:24'hFFFFFF;

        if (logo_area_q0) begin
            case (logo_index)
                2'd1: rgb_with_logo = 24'h1B2A52;
                2'd2: rgb_with_logo = 24'hE3262E;
                default: rgb_with_logo = rgb_adjusted;
            endcase
        end
        // 右下角运行时长：和 Logo 一样放在亮度/对比度调节之后合成，
        // 免得调画面时把时间戳一起调暗。
        if (ts_paint1)
            rgb_with_logo = ts_dark1 ? 24'h000000 : 24'hFFFFFF;
        // 亮度/对比度名称标签：字身用条本身的配色（亮度金黄 / 对比度紫）+ 黑描边，
        // 同样放在调节之后，否则调亮度会把标签自己也改色。
        if (nam_mode1 && (glyph_mask != 2'd0))
            rgb_with_logo = (glyph_mask == 2'd1) ? 24'h000000 : adj_color1;
        // Mode text sits beside the Logo and remains independent of picture
        // brightness/contrast adjustment, like the Logo and timestamp.
        if (mode_notice_mode1 && (glyph_mask != 2'd0))
            rgb_with_logo = (glyph_mask == 2'd1) ? 24'h000000 : 24'hFFFFFF;
    end

    assign hs_out = hs1;
    assign vs_out = vs1;
    assign de_out = de1;
    assign rgb_out = plain1 ? ((step_text1 && glyph_mask!=0)?(glyph_mask==1?24'h000000:24'hFFFFFF):rgb_adjusted) : rgb_with_logo;
endmodule
