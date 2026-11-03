// Generated from the approved Xiaoxiao word-level timing data.
// Time base: first real I2S sample = frame 0; video frame rate = 60 Hz.

function [1:0] osd_sub_track;
    input [4:0] id;
    begin
        case (id)
            5'd0, 5'd1, 5'd2, 5'd3: osd_sub_track = 2'd0;
            5'd4, 5'd5, 5'd6:       osd_sub_track = 2'd1;
            5'd7, 5'd8, 5'd9:       osd_sub_track = 2'd2;
            5'd10,5'd11,5'd12:      osd_sub_track = 2'd3;
            default:                osd_sub_track = 2'd0;
        endcase
    end
endfunction
function [16:0] osd_sub_start;
    input [4:0] id;
    begin
        case (id)
            5'd0:  osd_sub_start = 17'd7;   // AUDIO1 0.12s
            5'd1:  osd_sub_start = 17'd253; // AUDIO1 4.218s
            5'd2:  osd_sub_start = 17'd401; // AUDIO1 6.691s
            5'd3:  osd_sub_start = 17'd511; // AUDIO1 8.509s
            5'd4:  osd_sub_start = 17'd7;   // AUDIO2 0.12s
            5'd5:  osd_sub_start = 17'd246; // AUDIO2 4.105s
            5'd6:  osd_sub_start = 17'd423; // AUDIO2 7.045s
            5'd7:  osd_sub_start = 17'd7;   // AUDIO3 0.12s
            5'd8:  osd_sub_start = 17'd227; // AUDIO3 3.778s
            5'd9:  osd_sub_start = 17'd389; // AUDIO3 6.477s
            5'd10: osd_sub_start = 17'd7;   // AUDIO4 0.12s
            5'd11: osd_sub_start = 17'd203; // AUDIO4 3.38s
            5'd12: osd_sub_start = 17'd330; // AUDIO4 5.494s
            default: osd_sub_start = 17'd0;
        endcase
    end
endfunction

function [16:0] osd_sub_end;
    input [4:0] id;
    begin
        case (id)
            5'd0:  osd_sub_end = 17'd238; // 3.963s
            5'd1:  osd_sub_end = 17'd373; // 6.221s
            5'd2:  osd_sub_end = 17'd499; // 8.31s
            5'd3:  osd_sub_end = 17'd594; // 9.901s
            5'd4:  osd_sub_end = 17'd230; // 3.835s
            5'd5:  osd_sub_end = 17'd406; // 6.761s
            5'd6:  osd_sub_end = 17'd539; // 8.991s
            5'd7:  osd_sub_end = 17'd205; // 3.409s
            5'd8:  osd_sub_end = 17'd372; // 6.207s
            5'd9:  osd_sub_end = 17'd497; // 8.281s
            5'd10: osd_sub_end = 17'd188; // 3.139s
            5'd11: osd_sub_end = 17'd302; // 5.028s
            5'd12: osd_sub_end = 17'd462; // 7.696s
            default: osd_sub_end = 17'd0;
        endcase
    end
endfunction

// ===================================================================
// Callout (引出线标注) timing table
// -------------------------------------------------------------------
// 8 labels total.  Label order MUST match generate_osd_assets.ps1.
//   index 0..4 -> PHOTO1 (track 0)
//   index 5..6 -> PHOTO2 (track 1)
//   index 7    -> PHOTO3 (track 2)
//   PHOTO4     -> no callout at all
//
// osd_callout_show(id) = W : the frame at which the label TEXT becomes fully
//                           visible (measured against the word's onset in
//                           Xiaoxiao's word-level timeline, 60 Hz).
// osd_callout_fade(id) = F : the frame at which the whole callout starts to
//                           fade out.  17'd99999 = never (stays until the
//                           photo is switched).
//
// Animation rule (see osd_controller.v):
//   W-20 .. W-14  dot fades in
//   W-14 .. W-6   leader line flows out of the dot (8 steps)
//   W-6  .. W     text fades in
//   W    .. F     fully visible
//   F    .. F+12  everything fades out together
// ===================================================================

function [1:0] osd_callout_track;
    input [2:0] id;
    begin
        case (id)
            3'd0, 3'd1, 3'd2, 3'd3, 3'd4: osd_callout_track = 2'd0; // PHOTO1
            3'd5, 3'd6:                   osd_callout_track = 2'd1; // PHOTO2
            3'd7:                         osd_callout_track = 2'd2; // PHOTO3
            default:                      osd_callout_track = 2'd0;
        endcase
    end
endfunction

function [16:0] osd_callout_show;
    input [2:0] id;
    begin
        case (id)
            3'd0: osd_callout_show = 17'd207; // 滤杯       AUDIO1 3.451s
            3'd1: osd_callout_show = 17'd253; // 手冲壶     AUDIO1 4.218s
            3'd2: osd_callout_show = 17'd96;  // 咖啡豆     AUDIO1 1.605s
            3'd3: osd_callout_show = 17'd157; // 滤纸       AUDIO1 2.613s
            3'd4: osd_callout_show = 17'd329; // 咖啡杯     AUDIO1 5.482s
            3'd5: osd_callout_show = 17'd114; // 手摇磨豆机 AUDIO2 1.903s
            3'd6: osd_callout_show = 17'd114; // 研磨       AUDIO2 1.903s
            3'd7: osd_callout_show = 17'd431; // 萃取       AUDIO3 7.184s (0.5s early)
            default: osd_callout_show = 17'd0;
        endcase
    end
endfunction

function [16:0] osd_callout_fade;
    input [2:0] id;
    begin
        case (id)
            // PHOTO1: all five fade out together when "器具" starts (6.691s)
            3'd0, 3'd1, 3'd2, 3'd3, 3'd4: osd_callout_fade = 17'd401;
            // PHOTO2: both fade out when "粗细" finishes (3.835s)
            3'd5, 3'd6:                   osd_callout_fade = 17'd230;
            // PHOTO3: last word of the track -> never fades, goes with the photo
            3'd7:                         osd_callout_fade = 17'd99999;
            default:                      osd_callout_fade = 17'd99999;
        endcase
    end
endfunction
