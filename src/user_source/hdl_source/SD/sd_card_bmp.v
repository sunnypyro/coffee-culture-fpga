
module sd_card_bmp #(
    parameter integer CLK_FREQ_HZ       = 100_000_000,
    parameter [31:0]  SCAN_START_SECTOR = 32'd0,
    parameter [31:0]  SCAN_MAX_SECTOR   = 32'd131071,
    parameter [2:0]   SCAN_TARGET_COUNT = 3'd4,
    parameter integer FAST_DWELL_MS     = 2000
)(
    input                       clk,
    input                       rst,
    input picker_cmd_valid,
    input [2:0] picker_cmd_kind,
    input [1:0] picker_cmd_idx,
    input picker_display_ready,picker_normal_visible,picker_view_ready,
    input picker_result_valid,
    input [7:0] picker_result_id,
    input [1:0] picker_result_code,
    input picker_writer_abort_done,picker_img_inflight,picker_audio_need,picker_hold_applied,
    output picker_menu_active,picker_body_hold,picker_select_enabled,picker_entry_quiesce,
    output picker_thumb,picker_abort,picker_view_send,picker_view_cancel,
    output [7:0] picker_view_id,
    output [1:0] picker_view_source,
    output [20:0] picker_tile_base,
    output [15:0] picker_view_width,picker_view_height,
    output [1:0] picker_view_img,
    output picker_closed_event,picker_selected_event,
    output [1:0] picker_selected_idx,picker_selected_buf,
    output picker_feedback_wait,picker_selecting,
    input                       key_next,
    input                       key_auto,
    input                       pause_state,
    input                       video_vsync_async,
    input                       media_ready,
    input  [31:0]               photo1_sector,
    input  [31:0]               photo2_sector,
    input  [31:0]               photo3_sector,
    input  [31:0]               photo4_sector,
    input                       audio_done,
    input                       audio_failed,
    input  [3:0]                group_ok_mask,   // bit N: group N has BOTH picture and song
    input  [3:0]                fast_ok_mask,    // Pictures present, irrespective of narration.
    output [3:0]                state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output [15:0]               hdr_width,
    output [15:0]               hdr_height,
    output                      hdr_toggle,
    output reg                  display_valid,

    input                       write_finish_toggle,
    output reg [1:0]            write_buf_idx,
    output reg [1:0]            disp_buf_idx,
    output reg                  display_commit_toggle,
    output reg                  display_commit_req_toggle,
    input                       display_commit_ack_toggle,
    output wire [1:0]           current_img_idx,
    output wire                 image_load_busy,
    output reg                  track_start,
    output reg [1:0]            track_idx,
    output reg                  auto_play_en,
    output reg                  fast_cycle_en,

    output                      write_req,
    input                       write_req_ack,
    output                      write_en,
    output [31:0]               write_data,
    input                       sd_init_done,
    output                      sd_sec_read,
    output [31:0]               sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end
);

wire key_next_press;
wire key_auto_press;
reg  pause_sync0;
reg  pause_sync1;
reg  fast_cycle_en_d;
reg  write_done_pending;
reg  frame_write_started_seen;
reg  transition_commit_wait;
reg  ack_sync0;
reg  ack_sync1;
reg  write_ack_meta, write_ack_sync;

// The memory-side ACK is held until the request is withdrawn. Only the
// second receiving-clock stage may drive the BMP state machine.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        write_ack_meta <= 1'b0;
        write_ack_sync <= 1'b0;
    end else begin
        write_ack_meta <= write_req_ack;
        write_ack_sync <= write_ack_meta;
    end
end

reg  display_commit_ack_seen;

wire             bmp_data_wr_en;
wire [23:0]      bmp_data;
wire [15:0]      bmp_src_width;
wire [15:0]      bmp_src_height;
wire             bmp_data_start;
wire             scaler_in_ready;
wire             scaler_out_valid;
wire [23:0]      scaler_out_pixel;
wire             scaler_done;
wire             bmp_reader_ready;
wire             bmp_ready;
reg              scaler_done_seen;
reg              bmp_read_active_seen;
wire             bmp_load_failed;   // 图加载失败（图头不对 / 等写通道超时）
wire             bmp_scan_done;
wire             bmp_scan_found_valid;
wire [31:0]      bmp_scan_found_sector;
wire [2:0]       bmp_scan_found_total;
wire             scan_done = media_ready;

reg              scan_start_pulse;
reg              load_start_pulse;
reg              load_prepare_pending;
reg [31:0]       load_sector;
reg              scan_kicked;
reg              first_image_committed;
reg [31:0]       auto_cnt;
reg [2:0]        img_found_count;
reg [3:0]        group_ok_mask_latched;
reg [2:0]        photo_found_count;
reg [3:0]        photo_ok_mask_latched;
reg [1:0]        img_idx;              // 当前真正显示中的图片编号
reg [1:0]        load_idx;             // 当前正在写入的图片编号
reg [1:0]        pending_buf_idx;      // 当前正在写入的目标缓冲区
reg [31:0]       img_sector0;
reg [31:0]       img_sector1;
reg [31:0]       img_sector2;
reg [31:0]       img_sector3;
reg              next_req_pending;
reg              load_busy;
reg              auto_tail_pending;
reg              auto_prefetch_pending;
reg              manual_prefetch_pending;

wire pv_thumb_start,pv_full_start,pv_abort_normal_done;
wire[1:0]pv_thumb_idx,pv_full_idx,pv_full_buf;
wire[3:0]pv_tile_mask;
wire bmp_abort_done;
reg[1:0]writer_abort_sync;
reg[1:0]display_ready_sync;reg[1:0]hold_applied_sync;
reg pv_menu_prev;
reg[1:0]cache_valid;
reg[1:0]cache_idx0,cache_idx1;
reg[15:0]cache_w0,cache_w1,cache_h0,cache_h1;
wire[15:0]raw_hdr_width,raw_hdr_height;wire raw_hdr_toggle;
reg raw_hdr_seen,hdr_publish_toggle;
reg[15:0]hdr_publish_width,hdr_publish_height;
reg audio_advance_pending;
wire picker_freeze=picker_menu_active&&display_valid;
wire physical_write_finish_pulse;
wire thumb_valid,thumb_done,thumb_bad;wire[23:0]thumb_pixel;
// bmp_ready 先表示“源文件读取/送 FIFO 完成”；真正切显示要等 write_finish_toggle 同步后
reg              source_done_seen;

// 同步 mem_clk 域的 write_finish_toggle
reg [2:0]        wrfin_tgl_sync;
wire             write_finish_pulse;

wire [1:0] next_from_current;
wire       auto_advance_start;
wire       auto_prefetch_start;
wire       manual_prefetch_start;
wire       auto_tail_start;
wire       auto_tail_done;

// 下一个可用的组：从当前组的下一组开始找，最多绕一圈。
// mask 里为 0 的组（图或歌缺失）直接跳过。
function [1:0] next_usable;
    input [1:0] cur;
    input [3:0] mask;
    reg [1:0] c1, c2, c3;
    begin
        c1 = cur + 2'd1;
        c2 = cur + 2'd2;
        c3 = cur + 2'd3;
        if (mask[c1])      next_usable = c1;
        else if (mask[c2]) next_usable = c2;
        else if (mask[c3]) next_usable = c3;
        else               next_usable = cur;   // 只有当前这一组可用
    end
endfunction

// 第一个可用的组（开机加载用）
function [1:0] first_usable;
    input [3:0] mask;
    begin
        if (mask[0])      first_usable = 2'd0;
        else if (mask[1]) first_usable = 2'd1;
        else if (mask[2]) first_usable = 2'd2;
        else              first_usable = 2'd3;
    end
endfunction

wire picker_abort_control;
reg [1:0] normal_error_state;
reg normal_error_manual,normal_error_background_auto,normal_error_next;
wire normal_error_start = load_busy && bmp_load_failed && !picker_thumb && !picker_menu_active;
wire normal_error_pending = normal_error_start || normal_error_state!=0;
wire normal_error_release = normal_error_state==2 && !bmp_abort_done && !writer_abort_sync[1] && bmp_reader_ready;
assign picker_abort = picker_abort_control || normal_error_state==1;
always @(posedge clk or posedge rst) begin
 if(rst)begin normal_error_state<=0;normal_error_manual<=0;normal_error_background_auto<=0;normal_error_next<=0;end
 else if(!sd_init_done)begin normal_error_state<=0;normal_error_manual<=0;normal_error_background_auto<=0;normal_error_next<=0;end
 else begin
 if(normal_error_pending && key_next_press)normal_error_next<=1;
 case(normal_error_state)
  0:if(normal_error_start)begin
   normal_error_state<=1;
   // Another abort owner may clear live mode flags before both sides release.
   normal_error_manual<=manual_prefetch_pending;
   normal_error_background_auto<=auto_prefetch_pending && !auto_tail_pending;
   normal_error_next<=next_req_pending || key_next_press;
  end
  1:if(bmp_abort_done && writer_abort_sync[1])normal_error_state<=2;
  2:if(normal_error_release)normal_error_state<=0;
  default:normal_error_state<=0;
 endcase
 end
end
assign bmp_ready  = bmp_reader_ready && scaler_done_seen;
assign write_en   = !normal_error_pending&&!picker_abort&&(picker_thumb?thumb_valid:scaler_out_valid);
assign write_data = {scaler_out_pixel[23:16], scaler_out_pixel[15:8], scaler_out_pixel[7:0], 8'b0};
// 三种模式用不同的"可用组"判据：
//   手动 / 快速轮播：只要卡上有图就能播（fast_ok_mask）
//   自动跟读      ：图和歌必须成组（group_ok_mask）
// 这样卡里没有 wav 人声文件时，手动和快速轮播照样能出图；自动跟读仍会跳过缺歌的组。
//
// ★ 这一对必须**寄存**再往下用。它们是 next_usable() → sector_lut() → load_sector
//   这条 32 位组合链的第一级，而 fast_cycle_en / auto_play_en 是模式寄存器的输出。
//   实测不寄存时，sd_card_clk 的 WNS 会变成
//   "fast_cycle_en_reg → load_sector_reg[3]"（−0.832ns，全组最差）。
//   模式切换晚 1 拍生效没有任何副作用：真正启动预取要等 key_auto_press 撤掉之后。
wire [3:0] active_mask_next = (!auto_play_en || fast_cycle_en) ? photo_ok_mask_latched
                                                               : group_ok_mask_latched;
wire [2:0] active_found_next = (!auto_play_en || fast_cycle_en) ? photo_found_count
                                                                : img_found_count;
reg  [3:0] active_mask;
reg  [2:0] active_found_count;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        active_mask        <= 4'd0;
        active_found_count <= 3'd0;
    end else begin
        active_mask        <= active_mask_next;
        active_found_count <= active_found_next;
    end
end

// 快速轮播的 2 秒节拍：到点标志是锁存电平，见 photo_fast_dwell 的注释。
wire       dwell_expired;
wire       img_commit_pulse;
// 自动跟读靠人声播完推进；快速轮播靠 2 秒到点推进。
wire       advance_evt = fast_cycle_en ? dwell_expired : (audio_done||audio_advance_pending);

assign next_from_current = next_usable(img_idx, active_mask);
assign write_finish_pulse = physical_write_finish_pulse&&!picker_thumb;
assign current_img_idx = img_idx;
assign image_load_busy = load_busy &&
                         (!manual_prefetch_pending || next_req_pending || key_next_press);
assign auto_advance_start = !picker_freeze&&!picker_thumb&&!pause_sync1 && scan_done && bmp_ready && display_valid &&
                              !load_busy && auto_play_en && advance_evt &&
                              !auto_prefetch_pending && !manual_prefetch_pending &&
                              (active_found_count > 3'd1);
assign auto_prefetch_start = !picker_freeze&&!picker_thumb&&!pause_sync1 && scan_done && bmp_ready && display_valid &&
                              !load_busy && !auto_prefetch_pending && !manual_prefetch_pending &&
                              auto_play_en && !key_auto_press &&
                              (active_found_count > 3'd1);
assign manual_prefetch_start = !picker_freeze&&!picker_thumb&&!pause_sync1 && scan_done && bmp_ready && display_valid &&
                               !load_busy && !auto_prefetch_pending && !manual_prefetch_pending &&
                               !auto_play_en && !key_auto_press &&
                               !next_req_pending && !key_next_press && !audio_failed &&
                               (active_found_count > 3'd1);
assign auto_tail_start = !picker_freeze&&(auto_advance_start ||
                         (!pause_sync1 && advance_evt &&
                          (auto_prefetch_pending || auto_prefetch_start) &&
                          !auto_tail_pending));

assign physical_write_finish_pulse=wrfin_tgl_sync[2]^wrfin_tgl_sync[1];
assign picker_tile_base=21'd614400+(pv_thumb_idx[1]?21'd153600:21'd0)+(pv_thumb_idx[0]?21'd320:21'd0);
assign hdr_width=hdr_publish_width;assign hdr_height=hdr_publish_height;assign hdr_toggle=hdr_publish_toggle;
assign picker_view_width=picker_view_source==1?cache_w1:cache_w0;
assign picker_view_height=picker_view_source==1?cache_h1:cache_h0;
assign picker_view_img=picker_view_source==1?cache_idx1:cache_idx0;
always @(posedge clk or posedge rst)begin
 if(rst)begin writer_abort_sync<=0;display_ready_sync<=0;hold_applied_sync<=0;pv_menu_prev<=0;audio_advance_pending<=0;end
 else begin
  writer_abort_sync<={writer_abort_sync[0],picker_writer_abort_done};hold_applied_sync<={hold_applied_sync[0],picker_hold_applied};
  display_ready_sync<={display_ready_sync[0],picker_display_ready};pv_menu_prev<=picker_menu_active;
  if(audio_done&&(picker_thumb||picker_freeze))audio_advance_pending<=1;
  if(auto_tail_start||picker_selected_event||key_auto_press)audio_advance_pending<=0;
 end
end
always @(posedge clk or posedge rst)begin
 if(rst)begin
  cache_valid<=0;cache_idx0<=0;cache_idx1<=0;cache_w0<=0;cache_w1<=0;cache_h0<=0;cache_h1<=0;
  raw_hdr_seen<=0;hdr_publish_toggle<=0;hdr_publish_width<=0;hdr_publish_height<=0;
 end else begin
  raw_hdr_seen<=raw_hdr_toggle;
  if(load_start_pulse&&!picker_thumb)cache_valid[write_buf_idx[0]]<=0;
  if(pv_full_start)cache_valid[pv_full_buf[0]]<=0;
  if(raw_hdr_toggle!=raw_hdr_seen&&!picker_thumb)begin
   hdr_publish_width<=raw_hdr_width;hdr_publish_height<=raw_hdr_height;hdr_publish_toggle<=~hdr_publish_toggle;
   if(write_buf_idx[0])begin cache_w1<=raw_hdr_width;cache_h1<=raw_hdr_height;cache_idx1<=load_idx;end
   else begin cache_w0<=raw_hdr_width;cache_h0<=raw_hdr_height;cache_idx0<=load_idx;end
  end
  if(!normal_error_pending&&load_busy&&source_done_seen&&(write_done_pending||write_finish_pulse)&&!picker_thumb)
   cache_valid[pending_buf_idx[0]]<=1;
  if(normal_error_pending)cache_valid[pending_buf_idx[0]]<=0;
  if(pv_abort_normal_done)cache_valid[write_buf_idx[0]]<=0;
 end
end
picker_thumbnail u_picker_thumbnail(clk,rst,bmp_data_start,picker_abort,scaler_out_valid,scaler_out_pixel,
 thumb_valid,thumb_pixel,thumb_done,thumb_bad);
picker_control #(.CLK_HZ(CLK_FREQ_HZ))u_picker_control(
 .clk(clk),.rst(rst),.cmd_valid(picker_cmd_valid),.cmd_kind(picker_cmd_kind),.cmd_idx(picker_cmd_idx),
 .display_ready(display_ready_sync[1]),.voice_hold_applied(hold_applied_sync[1]),
 .normal_idle(!normal_error_pending&&!next_req_pending&&bmp_ready&&(!load_busy||(source_done_seen&&write_done_pending))&&!load_prepare_pending&&!auto_prefetch_start&&!manual_prefetch_start),
 .normal_urgent(key_next_press||key_auto_press||advance_evt||next_req_pending),.normal_visible(picker_normal_visible),.transition_wait(transition_commit_wait),
 .raw_idle(bmp_ready),.raw_data_start(bmp_data_start),.raw_failed(bmp_load_failed||(picker_thumb&&thumb_bad)),
 .raw_write_done(physical_write_finish_pulse),.raw_progress(sd_sec_read_data_valid||scaler_out_valid),.audio_need(picker_audio_need),
 .full_done(source_done_seen&&write_done_pending),
 .abort_ack(bmp_abort_done&&writer_abort_sync[1]),.abort_released(!bmp_abort_done&&!writer_abort_sync[1]),
 .current_buf(disp_buf_idx),.current_idx(img_idx),.photo_mask(photo_ok_mask_latched),
 .cache0_valid(cache_valid[0]),.cache1_valid(cache_valid[1]),.cache0_idx(cache_idx0),.cache1_idx(cache_idx1),
 .view_ready(picker_view_ready),.view_result_valid(picker_result_valid),.view_result_id(picker_result_id),.view_result_code(picker_result_code),
 .menu_active(picker_menu_active),.body_hold(picker_body_hold),.select_enabled(picker_select_enabled),.entry_quiesce(picker_entry_quiesce),
 .thumb_active(picker_thumb),.thumb_start(pv_thumb_start),.thumb_idx(pv_thumb_idx),
 .full_start(pv_full_start),.full_idx(pv_full_idx),.full_buf(pv_full_buf),.abort_req(picker_abort_control),.abort_normal_done(pv_abort_normal_done),
 .view_send(picker_view_send),.view_cancel(picker_view_cancel),.view_id(picker_view_id),.view_source(picker_view_source),
 .selected_commit(picker_selected_event),.selected_idx(picker_selected_idx),.selected_buf(picker_selected_buf),
 .closed_event(picker_closed_event),.feedback_wait(picker_feedback_wait),.selecting(picker_selecting),.tile_valid_mask(pv_tile_mask));



always @(posedge clk or posedge rst) begin
    if (rst)
        scaler_done_seen <= 1'b1;
    else if (picker_abort || bmp_load_failed || !sd_init_done)
        scaler_done_seen <= 1'b1;
    else if (bmp_data_start)
        scaler_done_seen <= 1'b0;
    else if (scaler_done)
        scaler_done_seen <= 1'b1;
end

// `bmp_read.ready` is also high before a request starts. Observe the busy
// phase before treating its later high level as source completion.
always @(posedge clk or posedge rst) begin
    if (rst)
        bmp_read_active_seen <= 1'b0;
    else if (!sd_init_done || !load_busy || load_start_pulse)
        bmp_read_active_seen <= 1'b0;
    else if (!bmp_reader_ready)
        bmp_read_active_seen <= 1'b1;
end

wire manual_prefetch_commit_allowed = !manual_prefetch_pending || next_req_pending;
wire fast_tail_done;
wire auto_tail_done_sel = fast_cycle_en ? fast_tail_done : auto_tail_done;
wire frame_commit_ready = !normal_error_pending && !picker_freeze&&!picker_thumb&&!pause_sync1 && !key_auto_press && load_busy && source_done_seen &&
                          (write_finish_pulse || write_done_pending) &&
                          (((!auto_prefetch_pending && !auto_tail_pending) &&
                            manual_prefetch_commit_allowed) ||
                           (auto_tail_pending && auto_tail_done_sel));
wire first_commit_now = frame_commit_ready && !transition_commit_wait && !display_valid;
wire request_transition = frame_commit_ready && !transition_commit_wait && display_valid;
wire ack_transition = transition_commit_wait && (ack_sync1 != display_commit_ack_seen);
wire commit_now = first_commit_now || ((!pause_sync1||picker_entry_quiesce) && ack_transition);
assign img_commit_pulse = commit_now;

audio_tail_frame_wait u_audio_tail_frame_wait (
    .clk               (clk),
    .rst               (rst),
    .start             (auto_tail_start),
    .hold_count        (picker_body_hold),
    .video_vsync_async (video_vsync_async),
    .wait_done         (auto_tail_done)
);

audio_tail_frame_wait #(
    .FRAME_COUNT (2)
) u_fast_tail_frame_wait (
    .clk               (clk),
    .rst               (rst),
    .start             (auto_tail_start),
    .hold_count        (picker_body_hold),
    .video_vsync_async (video_vsync_async),
    .wait_done         (fast_tail_done)
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_next (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_next),
    .press_pulse(key_next_press)
);

key_press_debounce #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DEBOUNCE_MS (20)
) u_key_auto (
    .clk        (clk),
    .rst        (rst),
    .button_in  (key_auto),
    .press_pulse(key_auto_press)
);

function [31:0] sector_lut;
    input [1:0] idx;
    begin
        case (idx)
            2'd0: sector_lut = img_sector0;
            2'd1: sector_lut = img_sector1;
            2'd2: sector_lut = img_sector2;
            2'd3: sector_lut = img_sector3;
            default: sector_lut = img_sector0;
        endcase
    end
endfunction

function [1:0] next_buf_lut;
    input [1:0] cur_disp_buf;
    input       valid_now;
    begin
        if (!valid_now)
            next_buf_lut = 2'd0;                 // 首图固定写 buffer0
        else if (cur_disp_buf == 2'd0)
            next_buf_lut = 2'd1;
        else
            next_buf_lut = 2'd0;
    end
endfunction

always @(posedge clk or posedge rst) begin
    if (rst) begin
        wrfin_tgl_sync        <= 3'b000;
        scan_start_pulse      <= 1'b0;
        load_start_pulse      <= 1'b0;
        load_prepare_pending  <= 1'b0;
        load_sector           <= 32'd0;
        scan_kicked           <= 1'b0;
        first_image_committed <= 1'b0;
        auto_play_en          <= 1'b0;
        fast_cycle_en         <= 1'b0;
        auto_tail_pending <= 1'b0;
        auto_prefetch_pending <= 1'b0;
        manual_prefetch_pending <= 1'b0;
        auto_cnt              <= 32'd0;
        img_found_count       <= 3'd0;
        photo_found_count     <= 3'd0;
        photo_ok_mask_latched <= 4'd0;
        group_ok_mask_latched <= 4'd0;
        img_idx               <= 2'd0;
        load_idx              <= 2'd0;
        pending_buf_idx       <= 2'd0;
        write_buf_idx         <= 2'd0;
        disp_buf_idx          <= 2'd0;
        display_commit_toggle <= 1'b0;
        display_commit_req_toggle <= 1'b0;
        transition_commit_wait <= 1'b0;
        ack_sync0             <= 1'b0;
        ack_sync1             <= 1'b0;
        display_commit_ack_seen <= 1'b0;
        img_sector0           <= 32'd0;
        img_sector1           <= 32'd0;
        img_sector2           <= 32'd0;
        img_sector3           <= 32'd0;
        next_req_pending      <= 1'b0;
        load_busy             <= 1'b0;
        source_done_seen      <= 1'b0;
        display_valid         <= 1'b0;
        track_start           <= 1'b0;
        track_idx             <= 2'd0;
        pause_sync0           <= 1'b0;
        pause_sync1           <= 1'b0;
        write_done_pending    <= 1'b0;
        frame_write_started_seen <= 1'b0;
    end else begin
        pause_sync0      <= pause_state;
        pause_sync1      <= pause_sync0;
        wrfin_tgl_sync   <= {wrfin_tgl_sync[1:0], write_finish_toggle};
        ack_sync0        <= display_commit_ack_toggle;
        ack_sync1        <= ack_sync0;
        scan_start_pulse <= 1'b0;
        load_start_pulse <= 1'b0;
        track_start      <= 1'b0;

        if (!sd_init_done) begin
            load_prepare_pending  <= 1'b0;
            scan_kicked           <= 1'b0;
            first_image_committed <= 1'b0;
            auto_play_en          <= 1'b0;
            fast_cycle_en         <= 1'b0;
            auto_tail_pending <= 1'b0;
            auto_prefetch_pending <= 1'b0;
            manual_prefetch_pending <= 1'b0;
            auto_cnt              <= 32'd0;
            img_found_count       <= 3'd0;
            photo_found_count     <= 3'd0;
            photo_ok_mask_latched <= 4'd0;
            group_ok_mask_latched <= 4'd0;
            img_idx               <= 2'd0;
            load_idx              <= 2'd0;
            pending_buf_idx       <= 2'd0;
            write_buf_idx         <= 2'd0;
            disp_buf_idx          <= 2'd0;
            display_commit_toggle <= 1'b0;
            display_commit_req_toggle <= 1'b0;
            transition_commit_wait <= 1'b0;
            display_commit_ack_seen <= 1'b0;
            ack_sync0             <= 1'b0;
            ack_sync1             <= 1'b0;
            img_sector0           <= 32'd0;
            img_sector1           <= 32'd0;
            img_sector2           <= 32'd0;
            img_sector3           <= 32'd0;
            next_req_pending      <= 1'b0;
            load_busy             <= 1'b0;
            source_done_seen      <= 1'b0;
            display_valid         <= 1'b0;
            track_start           <= 1'b0;
            track_idx             <= 2'd0;
            frame_write_started_seen <= 1'b0;
        end else begin
            if (!load_busy || load_start_pulse)
                frame_write_started_seen <= 1'b0;
            else if (bmp_data_start&&!picker_thumb)
                frame_write_started_seen <= 1'b1;

            if (auto_tail_start)
                auto_tail_pending <= 1'b1;

            // 记住 bmp_read 已经把源图送完 FIFO，但还不能切显示，得等整帧写完
            if (load_busy && bmp_read_active_seen && bmp_ready&&!picker_thumb)
                source_done_seen <= 1'b1;

            // The frame writer can drain its final pixel before the BMP reader
            // and scaler completion signals reach this clocked controller.
            // Retain a finish only after this load has started its own writer;
            // an old finish arriving before data_start is still ignored.
            if (load_busy && (frame_write_started_seen || bmp_data_start) && write_finish_pulse)
                write_done_pending <= 1'b1;

            // The first image establishes the display baseline directly. Later
            // frames wait until video has reached a safe transition point.
            if (request_transition) begin
                display_commit_req_toggle <= ~display_commit_req_toggle;
                transition_commit_wait    <= 1'b1;
            end

            if (!normal_error_pending && (first_commit_now || ((!pause_sync1||picker_entry_quiesce) && ack_transition))) begin
                if (ack_transition)
                    display_commit_ack_seen <= ack_sync1;
                transition_commit_wait <= 1'b0;
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                write_done_pending    <= 1'b0;
                frame_write_started_seen <= 1'b0;
                auto_tail_pending     <= 1'b0;
                auto_prefetch_pending <= 1'b0;
                manual_prefetch_pending <= 1'b0;
                next_req_pending      <= 1'b0;
                disp_buf_idx          <= pending_buf_idx;
                display_commit_toggle <= ~display_commit_toggle;
                img_idx               <= load_idx;
                display_valid         <= 1'b1;
                first_image_committed <= 1'b1;
                track_idx             <= load_idx;
                track_start           <= 1'b1;
            end

            // 图加载失败（图头不对 / 等写通道超时）：bmp_read 已经回到 IDLE，
            // 不会再产生 write_finish_toggle。此时必须把忙标志解除，否则所有换图
            // 分支都被 !load_busy 挡住、音频也被 image_load_busy 按住
            // ⇒ 整机永久卡死（2026-09-16 新增）。
            // 解除后置一次 next_req_pending，交给下面"手动下一张"分支去跳下一组。
            if (normal_error_release) begin
                load_prepare_pending <= 1'b0;
                load_busy        <= 1'b0;
                source_done_seen <= 1'b0;
                write_done_pending <= 1'b0;
                frame_write_started_seen <= 1'b0;
                transition_commit_wait <= 1'b0;
                if (normal_error_manual) begin
                    // A failed background read stays hidden until a manual
                    // request arrives; preserve a key request already latched.
                    manual_prefetch_pending <= 1'b0;
                    next_req_pending <= normal_error_next || next_req_pending || key_next_press;
                end else if (normal_error_background_auto) begin
                    // Retry through the normal audio-end path; do not skip while
                    // the current track is still playing.
                    auto_prefetch_pending <= 1'b0;
                    next_req_pending <= normal_error_next || next_req_pending || key_next_press;
                end else begin
                    auto_prefetch_pending <= 1'b0;
                    next_req_pending <= 1'b1;
                end
            end

            // FAT32 根目录扫描已按文件名找到了四张图片；
            // 保留原有双缓冲加载和按键控制，只使用准确的文件起始扇区。
            if (!scan_kicked && bmp_ready && media_ready) begin
                load_prepare_pending  <= 1'b0;
                scan_kicked           <= 1'b1;
                first_image_committed <= 1'b0;
                auto_play_en          <= 1'b0;
                fast_cycle_en         <= 1'b0;
                auto_tail_pending <= 1'b0;
                auto_prefetch_pending <= 1'b0;
                auto_cnt              <= 32'd0;
                // 可用组数 = mask 里 1 的个数（图和歌都在的组才算一组）
                group_ok_mask_latched <= group_ok_mask;
                img_found_count       <= group_ok_mask[0] + group_ok_mask[1] +
                                         group_ok_mask[2] + group_ok_mask[3];
                photo_ok_mask_latched <= fast_ok_mask;
                photo_found_count     <= fast_ok_mask[0] + fast_ok_mask[1] +
                                         fast_ok_mask[2] + fast_ok_mask[3];
                img_idx               <= 2'd0;
                load_idx              <= 2'd0;
                pending_buf_idx       <= 2'd0;
                write_buf_idx         <= 2'd0;
                disp_buf_idx          <= 2'd0;
                display_commit_toggle <= 1'b0;
                display_commit_req_toggle <= 1'b0;
                transition_commit_wait <= 1'b0;
                display_commit_ack_seen <= 1'b0;
                ack_sync0             <= 1'b0;
                ack_sync1             <= 1'b0;
                next_req_pending      <= 1'b0;
                display_valid         <= 1'b0;
                load_busy             <= 1'b0;
                source_done_seen      <= 1'b0;
                write_done_pending   <= 1'b0;
                frame_write_started_seen <= 1'b0;
                // 缺失的组不提供扇区地址（填 0，选择逻辑永远不会选中它）
                img_sector0           <= fast_ok_mask[0] ? photo1_sector : 32'd0;
                img_sector1           <= fast_ok_mask[1] ? photo2_sector : 32'd0;
                img_sector2           <= fast_ok_mask[2] ? photo3_sector : 32'd0;
                img_sector3           <= fast_ok_mask[3] ? photo4_sector : 32'd0;
            end else if(picker_selected_event)begin
                img_idx<=picker_selected_idx;disp_buf_idx<=picker_selected_buf;
                track_idx<=picker_selected_idx;track_start<=1;display_valid<=1;
                auto_play_en<=0;fast_cycle_en<=0;load_busy<=0;load_prepare_pending<=0;
                source_done_seen<=0;write_done_pending<=0;frame_write_started_seen<=0;
                auto_prefetch_pending<=0;manual_prefetch_pending<=0;auto_tail_pending<=0;
                next_req_pending<=0;transition_commit_wait<=0;
            end else if(normal_error_pending)begin
                load_prepare_pending<=0;source_done_seen<=0;write_done_pending<=0;
                frame_write_started_seen<=0;transition_commit_wait<=0;
            end else if(pv_full_start)begin
                load_idx<=pv_full_idx;pending_buf_idx<=pv_full_buf;write_buf_idx<=pv_full_buf;
                load_prepare_pending<=1;load_busy<=1;source_done_seen<=0;write_done_pending<=0;
                frame_write_started_seen<=0;manual_prefetch_pending<=0;auto_prefetch_pending<=0;
                next_req_pending<=0;auto_tail_pending<=0;
            end else if(pv_abort_normal_done)begin
                load_prepare_pending<=0;load_busy<=0;source_done_seen<=0;write_done_pending<=0;
                frame_write_started_seen<=0;manual_prefetch_pending<=0;auto_prefetch_pending<=0;
                transition_commit_wait<=0;next_req_pending<=0;
            end else begin
                if(picker_menu_active&&!pv_menu_prev&&!transition_commit_wait)next_req_pending<=0;
                // 忙的时候也只记 1 次“下一张”请求，不会累积成连跳两张
                if (!picker_freeze&&!pause_sync1 && key_next_press && scan_done && (active_found_count > 3'd0))
                    next_req_pending <= 1'b1;

                // KEY4：手动 -> 自动跟读 -> 快速轮播 -> 手动
                if (!picker_freeze&&!pause_sync1 && key_auto_press && scan_done && (photo_found_count > 3'd1)) begin
                    auto_cnt <= 32'd0;
                    if (!auto_play_en) begin
                        // 手动 -> 自动跟读
                        auto_play_en  <= 1'b1;
                        fast_cycle_en <= 1'b0;
                        if (manual_prefetch_pending) begin
                            manual_prefetch_pending <= 1'b0;
                            auto_prefetch_pending   <= 1'b1;
                        end
                    end else if (!fast_cycle_en) begin
                        // 自动跟读 -> 快速轮播：隐藏帧继续用，2 秒计时从切换点重新起算
                        fast_cycle_en <= 1'b1;
                        auto_tail_pending <= 1'b0;
                    end else begin
                        // 快速轮播 -> 手动
                        auto_play_en  <= 1'b0;
                        fast_cycle_en <= 1'b0;
                        auto_tail_pending <= 1'b0;
                        if (auto_prefetch_pending) begin
                            auto_prefetch_pending   <= 1'b0;
                            manual_prefetch_pending <= 1'b1;
                        end
                    end
                end

                // A bad current WAV keeps the existing skip-on-error behavior,
                // using the already-prefetched next frame when one is ready.
                if (!picker_freeze&&!pause_sync1 && manual_prefetch_pending && audio_failed)
                    next_req_pending <= 1'b1;

                // Automatic mode loads the next image at track start; audio end
                // only arms the tail wait and allows that image to be committed.
                auto_cnt <= 32'd0;

                // Reserve the load/indices first. The next cycle selects its
                // sector using the registered index, outside the request-priority chain.
                if (load_prepare_pending) begin
                    if (!pause_sync1||picker_menu_active) begin
                        load_sector <= sector_lut(load_idx);
                        load_start_pulse <= 1'b1;
                        load_prepare_pending <= 1'b0;
                    end
                end
                // 首图自动加载到 buffer0（从第一个可用的组开始）
                else if (!pause_sync1 && scan_done && !first_image_committed && bmp_ready && !load_busy && (active_found_count != 3'd0)) begin
                    load_idx         <= first_usable(active_mask);
                    pending_buf_idx  <= 2'd0;
                    write_buf_idx    <= 2'd0;
                    load_prepare_pending <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_pending <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 手动下一张优先：写到“非当前显示”的另一块 buffer
                else if (!picker_freeze&&!picker_thumb&&!pause_sync1 && scan_done && bmp_ready && display_valid && !load_busy &&
                         !auto_prefetch_pending && next_req_pending &&
                         (active_found_count != 3'd0)) begin
                    load_idx         <= next_from_current;
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_prepare_pending <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_pending <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // Both modes read one image ahead into the inactive buffer.
                // The mode selects only when that hidden frame may be committed.
                else if (auto_prefetch_start || manual_prefetch_start) begin
                    auto_prefetch_pending   <= auto_prefetch_start;
                    manual_prefetch_pending <= manual_prefetch_start;
                    load_idx         <= next_from_current;
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_prepare_pending <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_pending <= 1'b0;
                    next_req_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // Automatic mode can recover if its one-ahead read was not
                // available when the current audio stream ended.
                else if (auto_advance_start) begin
                    auto_prefetch_pending   <= 1'b1;
                    manual_prefetch_pending <= 1'b0;
                    load_idx         <= next_from_current;
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_prepare_pending <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
                // 这组的歌放不出来（WAV 格式错误）：不管手动还是自动模式，
                // 都跳到下一组，避免停在一张没有声音的画面上
                else if (!picker_freeze&&!picker_thumb&&!pause_sync1 && scan_done && bmp_ready && display_valid && !load_busy &&
                         !auto_prefetch_pending && audio_failed &&
                         (active_found_count > 3'd1)) begin
                    load_idx         <= next_from_current;
                    pending_buf_idx  <= next_buf_lut(disp_buf_idx, display_valid);
                    write_buf_idx    <= next_buf_lut(disp_buf_idx, display_valid);
                    load_prepare_pending <= 1'b1;
                    load_busy        <= 1'b1;
                    source_done_seen <= 1'b0;
                    write_done_pending <= 1'b0;
                    auto_cnt         <= 32'd0;
                end
            end
        end
    end
end

bmp_read bmp_read_m0(
    .abort_req(picker_abort),.img_inflight(picker_img_inflight),.abort_done(bmp_abort_done),
    .clk                    (clk),
    .rst                    (rst),
    .ready                  (bmp_reader_ready),

    .scan_start             (1'b0),
    .scan_start_sector      (SCAN_START_SECTOR),
    .scan_max_sector        (SCAN_MAX_SECTOR),
    .scan_target_count      (SCAN_TARGET_COUNT),
    .scan_done              (bmp_scan_done),
    .scan_found_valid       (bmp_scan_found_valid),
    .scan_found_sector      (bmp_scan_found_sector),
    .scan_found_total       (bmp_scan_found_total),

    .load_start             (load_start_pulse||pv_thumb_start),
    .load_sector            (picker_thumb?sector_lut(pv_thumb_idx):load_sector),

    .sd_init_done           (sd_init_done),
    .state_code             (state_code),
    .bmp_width              (bmp_width),
    .bmp_height             (bmp_height),
    .img_width              (bmp_src_width),
    .img_height             (bmp_src_height),
    .data_start             (bmp_data_start),
    .hdr_width              (raw_hdr_width),
    .hdr_height             (raw_hdr_height),
    .hdr_toggle             (raw_hdr_toggle),
    .write_req              (write_req),
    .write_req_ack          (write_ack_sync),
    .sd_sec_read            (sd_sec_read),
    .sd_sec_read_addr       (sd_sec_read_addr),
    .sd_sec_read_data       (sd_sec_read_data),
    .sd_sec_read_data_valid (sd_sec_read_data_valid),
    .sd_sec_read_end        (sd_sec_read_end),
    .bmp_data_ready         (scaler_in_ready),
    .bmp_data_wr_en         (bmp_data_wr_en),
    .bmp_data               (bmp_data),
    .load_failed            (bmp_load_failed)
);

img_scaler #(
    .DST_W      (640),
    .DST_H      (480),
    .SRC_W_MAX  (1024),
    .SRC_H_MAX  (2048)
) u_img_scaler (
    .clk        (clk),
    .rst        (rst||picker_abort),
    .start      (bmp_data_start),
    .src_w      (bmp_src_width),
    .src_h      (bmp_src_height),
    .in_valid   (bmp_data_wr_en),
    .in_ready   (scaler_in_ready),
    .in_pixel   (bmp_data),
    .out_valid  (scaler_out_valid),
    .out_pixel  (scaler_out_pixel),
    .done       (scaler_done)
);

// 快速轮播的 2 秒停留计时。clear 接"新图上屏"和"切入快速轮播"两种事件，
// 所以从人声模式切过来时会重新数 2 秒，不会立刻跳图。
always @(posedge clk or posedge rst) begin
    if (rst)
        fast_cycle_en_d <= 1'b0;
    else
        fast_cycle_en_d <= fast_cycle_en;
end

wire fast_cycle_enter = fast_cycle_en & ~fast_cycle_en_d;
photo_fast_dwell #(
    .CLK_FREQ_HZ (CLK_FREQ_HZ),
    .DWELL_MS    (FAST_DWELL_MS)
) u_photo_fast_dwell (
    .clk     (clk),
    .rst     (rst),
    .clear   (img_commit_pulse || fast_cycle_enter),
    .enable  (fast_cycle_en),
    .paused  (pause_sync1||picker_body_hold),
    .expired (dwell_expired)
);

endmodule

module audio_tail_frame_wait #(
    parameter integer FRAME_COUNT = 64
)(
    input  wire clk,
    input  wire rst,
    input  wire start,
    input wire hold_count,
    input  wire video_vsync_async,
    output reg  wait_done
);
    reg       vsync_meta;
    reg       vsync_sync;
    reg       vsync_sync_d;
    localparam integer FRAME_COUNTER_WIDTH = (FRAME_COUNT <= 64) ? 6 : 7;
    localparam [FRAME_COUNTER_WIDTH-1:0] LAST_FRAME = FRAME_COUNT - 1;

    reg [FRAME_COUNTER_WIDTH-1:0] frame_count;

    wire frame_rise = vsync_sync && !vsync_sync_d;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            vsync_meta   <= 1'b0;
            vsync_sync   <= 1'b0;
            vsync_sync_d <= 1'b0;
            frame_count  <= {FRAME_COUNTER_WIDTH{1'b0}};
            wait_done    <= 1'b1;
        end else begin
            vsync_meta   <= video_vsync_async;
            vsync_sync   <= vsync_meta;
            vsync_sync_d <= vsync_sync;

            if (start) begin
                frame_count <= {FRAME_COUNTER_WIDTH{1'b0}};
                wait_done   <= 1'b0;
            end else if (!wait_done && frame_rise && !hold_count) begin
                if (frame_count == LAST_FRAME) begin
                    frame_count <= {FRAME_COUNTER_WIDTH{1'b0}};
                    wait_done   <= 1'b1;
                end else begin
                    frame_count <= frame_count + {{(FRAME_COUNTER_WIDTH-1){1'b0}}, 1'b1};
                end
            end
        end
    end
endmodule

module audio_display_warmup_gate #(
    parameter integer FRAME_COUNT = 120
)(
    input  wire clk,
    input  wire rst,
    input  wire display_valid,
    input  wire video_vsync,
    output wire display_ready
);
    reg  warmup_started;
    wire warmup_start = display_valid && !warmup_started;
    wire warmup_done;

    always @(posedge clk or posedge rst) begin
        if (rst)
            warmup_started <= 1'b0;
        else if (!display_valid)
            warmup_started <= 1'b0;
        else
            warmup_started <= 1'b1;
    end

    audio_tail_frame_wait #(
        .FRAME_COUNT (FRAME_COUNT)
    ) u_warmup_frame_wait (
        .clk               (clk),
        .rst               (rst),
        .start             (warmup_start),
        .hold_count        (1'b0),
        .video_vsync_async (video_vsync),
        .wait_done         (warmup_done)
    );

    assign display_ready = display_valid && warmup_started && warmup_done;
endmodule

module key_press_debounce #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DEBOUNCE_MS = 20
)(
    input  wire clk,
    input  wire rst,
    input  wire button_in,    // 默认：松开=1，按下=0
    output reg  press_pulse
);

localparam integer DEBOUNCE_CYCLES = (CLK_FREQ_HZ / 1000) * DEBOUNCE_MS;

reg button_sync0;
reg button_sync1;
reg button_stable;
reg [31:0] cnt;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        button_sync0  <= 1'b1;
        button_sync1  <= 1'b1;
        button_stable <= 1'b1;
        cnt           <= 32'd0;
        press_pulse   <= 1'b0;
    end else begin
        button_sync0 <= button_in;
        button_sync1 <= button_sync0;
        press_pulse  <= 1'b0;

        if (button_sync1 == button_stable) begin
            cnt <= 32'd0;
        end else begin
            if (cnt >= DEBOUNCE_CYCLES - 1) begin
                if (button_stable && !button_sync1)
                    press_pulse <= 1'b1;
                button_stable <= button_sync1;
                cnt           <= 32'd0;
            end else begin
                cnt <= cnt + 32'd1;
            end
        end
    end
end

endmodule

// ---------------------------------------------------------------------------
// Q0.16 monotone phase remap for enlargement. The eight linear segments use
// knots from f(u)=u+1/4*u*(1-u)*(2u-1); endpoint and midpoint values are exact.
// ---------------------------------------------------------------------------
module f05_phase_coeff (
    input  wire [15:0] phase_in,
    output reg  [15:0] knot,
    output reg  [13:0] rise
);
    always @* begin
        knot = 16'd0;
        rise = 14'd8192;
        case (phase_in[15:13])
            3'd0: begin knot = 16'd0;     rise = 14'd6848; end
            3'd1: begin knot = 16'd6848;  rise = 14'd8000; end
            3'd2: begin knot = 16'd14848; rise = 14'd8768; end
            3'd3: begin knot = 16'd23616; rise = 14'd9152; end
            3'd4: begin knot = 16'd32768; rise = 14'd9152; end
            3'd5: begin knot = 16'd41920; rise = 14'd8768; end
            3'd6: begin knot = 16'd50688; rise = 14'd8000; end
            default: begin knot = 16'd58688; rise = 14'd6848; end
        endcase
    end
endmodule

module f05_phase_map (
    input  wire        enable,
    input  wire [15:0] phase_in,
    output reg  [15:0] phase_out
);
    wire [15:0] knot;
    wire [13:0] rise;
    reg [12:0] local_phase;
    reg [26:0] product;
    reg [16:0] curved_sum;

    f05_phase_coeff u_coeff (.phase_in(phase_in), .knot(knot), .rise(rise));

    always @* begin
        local_phase = phase_in[12:0];
        product = local_phase * rise;
        curved_sum = {1'b0, knot} + {3'd0, product[26:13]};
        if (!enable)
            phase_out = phase_in;
        else if (curved_sum[16])
            phase_out = 16'hFFFF;
        else
            phase_out = curved_sum[15:0];
    end
endmodule

// ---------------------------------------------------------------------------
// Streaming 24-bit RGB scaler. Three tagged source rows are kept in explicit
// dual-port BRAMs; the input side pauses before replacing either row used by
// the destination row currently being rendered.
// ---------------------------------------------------------------------------
module img_scaler #(
    parameter integer DST_W = 640,
    parameter integer DST_H = 480,
    parameter integer SRC_W_MAX = 1024,
    parameter integer SRC_H_MAX = 2048
)(
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [15:0] src_w,
    input  wire [15:0] src_h,
    input  wire        in_valid,
    output wire        in_ready,
    input  wire [23:0] in_pixel,
    output reg         out_valid,
    output reg  [23:0] out_pixel,
    output reg         done
);
    localparam integer POS_W = 27; // source coordinates use 11 integer and 16 fractional bits
    localparam integer DIV_W = 28; // numerator still represents 2048 * 65536
    localparam integer SRC_W_COUNT_W = (SRC_W_MAX > 1) ? $clog2(SRC_W_MAX + 1) : 1;
    localparam integer SRC_H_COUNT_W = (SRC_H_MAX > 1) ? $clog2(SRC_H_MAX + 1) : 1;
    localparam integer SRC_X_ADDR_W = (SRC_W_MAX > 1) ? $clog2(SRC_W_MAX) : 1;
    localparam integer SRC_Y_TAG_W = (SRC_H_MAX > 1) ? $clog2(SRC_H_MAX) : 1;
    localparam integer DST_X_W = (DST_W > 1) ? $clog2(DST_W) : 1;
    localparam integer DST_Y_W = (DST_H > 1) ? $clog2(DST_H) : 1;
    localparam integer DST_MAX = (DST_W > DST_H) ? DST_W : DST_H;
    localparam integer DIV_DEN_W = (DST_MAX > 1) ? $clog2(DST_MAX + 1) : 1;

    localparam [1:0] DIV_IDLE = 2'd0;
    localparam [1:0] DIV_RUN  = 2'd1;
    localparam [4:0] S_WAIT       = 5'd0;
    localparam [4:0] S_PHASE_X    = 5'd1;
    localparam [4:0] S_PHASE_Y    = 5'd2;
    localparam [4:0] S_READ_X0    = 5'd3;
    localparam [4:0] S_LATCH_X0   = 5'd4;
    localparam [4:0] S_READ_X1    = 5'd5;
    localparam [4:0] S_LATCH_X1   = 5'd6;
    localparam [4:0] S_MIX_H      = 5'd7;
    localparam [4:0] S_MIX_V      = 5'd8;
    localparam [4:0] S_EMIT       = 5'd9;
    localparam [4:0] S_ADVANCE    = 5'd10;
    localparam [4:0] S_WAIT_ROWS  = 5'd11;
    localparam [4:0] S_CHECK_ROWS = 5'd12;
    localparam [4:0] S_PHASE_X_ADD = 5'd13;
    localparam [4:0] S_PHASE_Y_ADD = 5'd14;
    localparam [4:0] S_MIX_H_ADD = 5'd15;
    localparam [4:0] S_MIX_V_ADD = 5'd16;

    localparam [15:0] DST_W_U16 = DST_W;
    localparam [15:0] DST_H_U16 = DST_H;
    localparam [POS_W-1:0] HALF_PIXEL_Q = 27'd32768;

    reg [SRC_W_COUNT_W-1:0] src_w_latched;
    // Precompute the terminal column before accepting pixels; keep the
    // width subtractor out of the row-tag write-enable path.
    reg [SRC_W_COUNT_W-1:0] src_w_last;
    // The divider/coordinate initialization holds input consumption closed
    // for many clocks after start, so this static decode settles first.
    always @(posedge clk) src_w_last <= src_w_latched - {{(SRC_W_COUNT_W-1){1'b0}},1'b1};
    reg [SRC_H_COUNT_W-1:0] src_h_latched;
    reg [SRC_H_COUNT_W-1:0] src_h_last;
    always @(posedge clk) src_h_last <= src_h_latched - {{(SRC_H_COUNT_W-1){1'b0}},1'b1};
    reg                      active;
    reg                      step_ready;
    reg                      coord_loaded;
    reg [4:0]                state;
    reg [DST_X_W-1:0]        dst_x;
    reg [DST_Y_W-1:0]        dst_y;
    reg [POS_W-1:0]          x_acc;
    reg [POS_W-1:0]          y_acc;
    reg [POS_W-1:0]          x_step;
    reg [POS_W-1:0]          y_step;
    reg [POS_W-1:0]          x_center_start;
    reg [POS_W-1:0]          y_center_start;

    // One restoring divider is reused for X then Y. It avoids a wide
    // combinational divide in the 100 MHz SD clock domain.
    reg [1:0]                div_state;
    reg                      div_axis;
    reg [4:0]                div_bit;
    reg [DIV_W-1:0]          div_num;
    reg [DIV_W-1:0]          div_quot;
    reg [DIV_DEN_W-1:0]      div_den;
    reg [DIV_DEN_W-1:0]      div_rem;

    wire [DIV_DEN_W:0] div_rem_shift = {div_rem, div_num[div_bit]};
    wire [DIV_DEN_W:0] div_den_ext = {1'b0, div_den};
    wire div_subtract = (div_rem_shift >= div_den_ext);
    wire [DIV_DEN_W-1:0] div_rem_next = div_subtract ?
        (div_rem_shift - div_den_ext) : div_rem_shift[DIV_DEN_W-1:0];
    wire [DIV_W-1:0] div_quot_next = {div_quot[DIV_W-2:0], div_subtract};

    // Input row ring and row tags. The count width can represent the terminal
    // value 2048; the three row tags need only represent 0..2047.
    reg [SRC_W_COUNT_W-1:0] in_col;
    reg [SRC_H_COUNT_W-1:0] in_row;
    reg [1:0]               write_bank;
    reg                     input_buffer_valid;
    reg [23:0]              input_buffer_pixel;
    reg                     row0_valid, row1_valid, row2_valid;
    reg [SRC_Y_TAG_W-1:0]   row0_tag, row1_tag, row2_tag;
    reg [SRC_H_COUNT_W-1:0] protect_y0, protect_y1;
    reg                      protection_valid;
    reg                      protection_pending;

    // Compute neighbors from the accumulator in parallel with the terminal
    // output-coordinate decode. Selecting the clamped result LAST removes
    // dst_x/y -> mux -> compare -> increment from the coordinate path.
    wire force_x_last = (src_w_latched <= DST_W_U16) && (dst_x == DST_W-1);
    wire force_y_last = (src_h_latched <= DST_H_U16) && (dst_y == DST_H-1);
    wire [SRC_W_COUNT_W-1:0] x_acc_floor = x_acc[16+SRC_W_COUNT_W-1:16];
    wire [POS_W-17:0] y_acc_integer = y_acc[POS_W-1:16];
    wire [SRC_H_COUNT_W-1:0] y_acc_floor = {{(SRC_H_COUNT_W-(POS_W-16)){1'b0}}, y_acc_integer};
    wire x_acc_last = (x_acc_floor == src_w_last);
    wire y_acc_last = (y_acc_floor == src_h_last);
    wire [SRC_W_COUNT_W-1:0] x_acc_next = x_acc_floor + {{(SRC_W_COUNT_W-1){1'b0}}, !x_acc_last};
    wire [SRC_H_COUNT_W-1:0] y_acc_next = y_acc_floor + {{(SRC_H_COUNT_W-1){1'b0}}, !y_acc_last};
    wire [SRC_W_COUNT_W-1:0] x0 = force_x_last ? src_w_last : x_acc_floor;
    wire [SRC_W_COUNT_W-1:0] x1 = force_x_last ? src_w_last : x_acc_next;
    wire [SRC_H_COUNT_W-1:0] y0 = force_y_last ? src_h_last : y_acc_floor;
    wire [SRC_H_COUNT_W-1:0] y1 = force_y_last ? src_h_last : y_acc_next;
    wire [15:0] wx_raw = (force_x_last || x_acc_last) ? 16'd0 : x_acc[15:0];
    wire [15:0] wy_raw = (force_y_last || y_acc_last) ? 16'd0 : y_acc[15:0];
    reg [SRC_X_ADDR_W-1:0] x0_sel, x1_sel;
    reg [SRC_H_COUNT_W-1:0] y0_sel, y1_sel;
    reg [1:0] y0_bank_sel, y1_bank_sel;
    reg [15:0] wx_raw_sel, wy_raw_sel;
    reg [15:0] wx_sel, wy_sel;
    wire [15:0] phase_input = (state == S_PHASE_X) ? wx_raw_sel : wy_raw_sel;
    wire phase_axis_is_x = (state == S_PHASE_X);
    wire [15:0] phase_knot;
    wire [13:0] phase_rise;
    wire [26:0] phase_product = phase_input[12:0] * phase_rise;
    reg [15:0] phase_knot_q, phase_raw_q;
    reg [26:0] phase_product_q;
    reg        phase_enable_q;
    wire [16:0] phase_sum_q = {1'b0, phase_knot_q} + {3'd0, phase_product_q[26:13]};
    wire [15:0] phase_mapped_q = phase_sum_q[16] ? 16'hFFFF : phase_sum_q[15:0];
    wire phase_axis_enable = phase_axis_is_x ?
        (src_w_latched < DST_W_U16) : (src_h_latched < DST_H_U16);
    f05_phase_coeff u_phase_coeff (
        .phase_in(phase_input), .knot(phase_knot), .rise(phase_rise)
    );

    // Weights are written before every pixel's mix states. Keeping their
    // local enables separate avoids a global reset/start mux at DSP inputs.
    always @(posedge clk) begin
        if (state == S_PHASE_X_ADD)
            wx_sel <= phase_enable_q ? phase_mapped_q : phase_raw_q;
        if (state == S_PHASE_Y_ADD)
            wy_sel <= phase_enable_q ? phase_mapped_q : phase_raw_q;
    end

    reg [2:0] y0_match_q, y1_match_q;
    wire [2:0] y0_match = {
        row2_valid && (row2_tag == y0_sel),
        row1_valid && (row1_tag == y0_sel),
        row0_valid && (row0_tag == y0_sel)
    };
    wire [2:0] y1_match = {
        row2_valid && (row2_tag == y1_sel),
        row1_valid && (row1_tag == y1_sel),
        row0_valid && (row0_tag == y1_sel)
    };
    wire y0_found_q = |y0_match_q;
    wire y1_found_q = |y1_match_q;
    wire [1:0] y0_bank_from_match = y0_match_q[0] ? 2'd0 : (y0_match_q[1] ? 2'd1 : 2'd2);
    wire [1:0] y1_bank_from_match = y1_match_q[0] ? 2'd0 : (y1_match_q[1] ? 2'd1 : 2'd2);
    reg row0_conflict, row1_conflict, row2_conflict;
    always @(posedge clk) begin
        row0_conflict <= row0_valid && ((row0_tag == protect_y0) || (row0_tag == protect_y1));
        row1_conflict <= row1_valid && ((row1_tag == protect_y0) || (row1_tag == protect_y1));
        row2_conflict <= row2_valid && ((row2_tag == protect_y0) || (row2_tag == protect_y1));
    end
    // The one-pixel skid alternates accept/consume, so successive input_fire
    // edges are at least two clocks apart. Decode the current column in the
    // intervening clock instead of feeding comparisons into row-tag enables.
    reg input_at_row_start, input_at_row_end;
    always @(posedge clk) begin
        input_at_row_start <= (in_col == {SRC_W_COUNT_W{1'b0}});
        input_at_row_end <= (in_col == src_w_last);
    end
    wire write_row_conflict = active && input_at_row_start &&
                              (((write_bank == 2'd0) && row0_conflict) ||
                               ((write_bank == 2'd1) && row1_conflict) ||
                               ((write_bank == 2'd2) && row2_conflict));
    wire input_consume_ready = step_ready && coord_loaded && (in_row < src_h_latched) &&
                               (!active || (protection_valid && !write_row_conflict));
    // Keep the row-tag conflict comparison local to the scaler. A one-pixel
    // skid register decouples BMP-sector BRAM enables from that long path.
    // bmp_read holds its current pixel until this capacity-only ready is high.
    assign in_ready = !input_buffer_valid;
    wire input_accept = in_valid && in_ready;
    wire input_fire = input_buffer_valid && input_consume_ready;
    wire store_input = input_fire && active;
    wire write_row0 = store_input && (write_bank == 2'd0);
    wire write_row1 = store_input && (write_bank == 2'd1);
    wire write_row2 = store_input && (write_bank == 2'd2);

    // BRAM row storage: 3 x 1024 x 24 bits, with independent write/read ports.
    wire [23:0] row0_q, row1_q, row2_q;
    wire row_read_active = (state == S_READ_X0) || (state == S_READ_X1);
    wire [1:0] selected_read_addr = (state == S_READ_X0) ? 2'd0 : 2'd1;
    wire [SRC_X_ADDR_W-1:0] active_read_addr = (selected_read_addr == 2'd0) ? x0_sel : x1_sel;
    wire row0_read = row_read_active && ((y0_bank_sel == 2'd0) || (y1_bank_sel == 2'd0));
    wire row1_read = row_read_active && ((y0_bank_sel == 2'd1) || (y1_bank_sel == 2'd1));
    wire row2_read = row_read_active && ((y0_bank_sel == 2'd2) || (y1_bank_sel == 2'd2));

    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(24), .ADDR_WIDTH_A(SRC_X_ADDR_W), .DATA_DEPTH_A(SRC_W_MAX),
        .DATA_WIDTH_B(24), .ADDR_WIDTH_B(SRC_X_ADDR_W), .DATA_DEPTH_B(SRC_W_MAX),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("9K"), .DEBUGGABLE("NO"), .PACKABLE("NO"),
        .INIT_FILE("NONE"), .FILL_ALL("NONE")
    ) u_source_row0 (
        .dia(input_buffer_pixel), .dib(24'd0), .addra(in_col[SRC_X_ADDR_W-1:0]), .addrb(active_read_addr),
        .cea(write_row0), .ceb(row0_read), .ocea(1'b0), .oceb(1'b0), .clka(clk), .clkb(clk),
        .wea(write_row0), .web(1'b0), .bea(1'b1), .beb(1'b0),
        .rsta(1'b0), .rstb(1'b0), .doa(), .dob(row0_q)
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(24), .ADDR_WIDTH_A(SRC_X_ADDR_W), .DATA_DEPTH_A(SRC_W_MAX),
        .DATA_WIDTH_B(24), .ADDR_WIDTH_B(SRC_X_ADDR_W), .DATA_DEPTH_B(SRC_W_MAX),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("9K"), .DEBUGGABLE("NO"), .PACKABLE("NO"),
        .INIT_FILE("NONE"), .FILL_ALL("NONE")
    ) u_source_row1 (
        .dia(input_buffer_pixel), .dib(24'd0), .addra(in_col[SRC_X_ADDR_W-1:0]), .addrb(active_read_addr),
        .cea(write_row1), .ceb(row1_read), .ocea(1'b0), .oceb(1'b0), .clka(clk), .clkb(clk),
        .wea(write_row1), .web(1'b0), .bea(1'b1), .beb(1'b0),
        .rsta(1'b0), .rstb(1'b0), .doa(), .dob(row1_q)
    );
    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A(24), .ADDR_WIDTH_A(SRC_X_ADDR_W), .DATA_DEPTH_A(SRC_W_MAX),
        .DATA_WIDTH_B(24), .ADDR_WIDTH_B(SRC_X_ADDR_W), .DATA_DEPTH_B(SRC_W_MAX),
        .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
        .IMPLEMENT("9K"), .DEBUGGABLE("NO"), .PACKABLE("NO"),
        .INIT_FILE("NONE"), .FILL_ALL("NONE")
    ) u_source_row2 (
        .dia(input_buffer_pixel), .dib(24'd0), .addra(in_col[SRC_X_ADDR_W-1:0]), .addrb(active_read_addr),
        .cea(write_row2), .ceb(row2_read), .ocea(1'b0), .oceb(1'b0), .clka(clk), .clkb(clk),
        .wea(write_row2), .web(1'b0), .bea(1'b1), .beb(1'b0),
        .rsta(1'b0), .rstb(1'b0), .doa(), .dob(row2_q)
    );

    reg [23:0] row0_pixel_q, row1_pixel_q;
    reg [23:0] sample00, sample01, sample10, sample11;
    reg [23:0] horizontal0, horizontal1;
    reg [23:0] mixed_pixel;
    always @* begin
        case (y0_bank_sel)
            2'd0: row0_pixel_q = row0_q;
            2'd1: row0_pixel_q = row1_q;
            2'd2: row0_pixel_q = row2_q;
            default: row0_pixel_q = 24'd0;
        endcase
        case (y1_bank_sel)
            2'd0: row1_pixel_q = row0_q;
            2'd1: row1_pixel_q = row1_q;
            2'd2: row1_pixel_q = row2_q;
            default: row1_pixel_q = 24'd0;
        endcase
    end

    function signed [24:0] mix_product;
        input [7:0] p0;
        input [7:0] p1;
        input [15:0] weight;
        reg signed [8:0] delta;
        reg signed [24:0] delta_ext;
        reg signed [24:0] weight_ext;
        begin
            delta = $signed({1'b0, p1}) - $signed({1'b0, p0});
            delta_ext = {{16{delta[8]}}, delta};
            weight_ext = {{9{1'b0}}, weight};
            mix_product = delta_ext * weight_ext;
        end
    endfunction

    function [74:0] mix_products_rgb;
        input [23:0] p0, p1;
        input [15:0] weight;
        begin
            mix_products_rgb = {mix_product(p0[23:16],p1[23:16],weight),
                mix_product(p0[15:8],p1[15:8],weight),mix_product(p0[7:0],p1[7:0],weight)};
        end
    endfunction
    function [7:0] mix_finish;
        input [7:0] p0;
        input signed [24:0] product;
        reg signed [27:0] sum;
        begin
            sum = $signed({4'd0,p0,16'd0}) + {{3{product[24]}},product} + 28'sd32768;
            mix_finish = sum[23:16];
        end
    endfunction
    function [23:0] mix_finish_rgb;
        input [23:0] p0;
        input [74:0] products;
        begin
            mix_finish_rgb = {mix_finish(p0[23:16],products[74:50]),
                mix_finish(p0[15:8],products[49:25]),mix_finish(p0[7:0],products[24:0])};
        end
    endfunction
    // Every product is overwritten before use. No reset mux is needed on
    // these pipeline banks; the existing DSPs may absorb their registers.
    reg [74:0] h_products0, h_products1, v_products;
    always @(posedge clk) begin
        if (!start && active && state == S_MIX_H) begin
            h_products0 <= mix_products_rgb(sample00,sample10,wx_sel);
            h_products1 <= mix_products_rgb(sample01,sample11,wx_sel);
        end
        if (!start && active && state == S_MIX_V)
            v_products <= mix_products_rgb(horizontal0,horizontal1,wy_sel);
    end

    // Input row/ring bookkeeping is the only writer of tags and input cursors.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            in_col <= {SRC_W_COUNT_W{1'b0}};
            in_row <= {SRC_H_COUNT_W{1'b0}};
            write_bank <= 2'd0;
            input_buffer_valid <= 1'b0;
            input_buffer_pixel <= 24'd0;
            row0_valid <= 1'b0; row1_valid <= 1'b0; row2_valid <= 1'b0;
            row0_tag <= {SRC_Y_TAG_W{1'b0}};
            row1_tag <= {SRC_Y_TAG_W{1'b0}};
            row2_tag <= {SRC_Y_TAG_W{1'b0}};
        end else if (start) begin
            in_col <= {SRC_W_COUNT_W{1'b0}};
            in_row <= {SRC_H_COUNT_W{1'b0}};
            write_bank <= 2'd0;
            input_buffer_valid <= 1'b0;
            row0_valid <= 1'b0; row1_valid <= 1'b0; row2_valid <= 1'b0;
        end else begin
            if (input_accept) begin
                input_buffer_valid <= 1'b1;
                input_buffer_pixel <= in_pixel;
            end else if (input_fire) begin
                input_buffer_valid <= 1'b0;
            end

            if (input_fire) begin
                if (active && input_at_row_start) begin
                    case (write_bank)
                        2'd0: row0_valid <= 1'b0;
                        2'd1: row1_valid <= 1'b0;
                        default: row2_valid <= 1'b0;
                    endcase
                end
                if (input_at_row_end) begin
                    in_col <= {SRC_W_COUNT_W{1'b0}};
                    in_row <= in_row + {{(SRC_H_COUNT_W-1){1'b0}},1'b1};
                    if (active) begin
                        case (write_bank)
                            2'd0: begin row0_valid <= 1'b1; row0_tag <= in_row[SRC_Y_TAG_W-1:0]; end
                            2'd1: begin row1_valid <= 1'b1; row1_tag <= in_row[SRC_Y_TAG_W-1:0]; end
                            default: begin row2_valid <= 1'b1; row2_tag <= in_row[SRC_Y_TAG_W-1:0]; end
                        endcase
                    end
                    if (write_bank == 2'd2)
                        write_bank <= 2'd0;
                    else
                        write_bank <= write_bank + 2'd1;
                end else begin
                    in_col <= in_col + {{(SRC_W_COUNT_W-1){1'b0}},1'b1};
                end
            end
        end
    end

    // Reused restoring divider for source-to-destination coordinate steps.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            div_state <= DIV_IDLE;
            div_axis <= 1'b0;
            div_bit <= 5'd0;
            div_num <= {DIV_W{1'b0}};
            div_quot <= {DIV_W{1'b0}};
            div_den <= {DIV_DEN_W{1'b0}};
            div_rem <= {DIV_DEN_W{1'b0}};
            step_ready <= 1'b0;
            x_step <= {POS_W{1'b0}}; y_step <= {POS_W{1'b0}};
            x_center_start <= {POS_W{1'b0}}; y_center_start <= {POS_W{1'b0}};
        end else if (start) begin
            step_ready <= 1'b0;
            div_rem <= {DIV_DEN_W{1'b0}};
            div_quot <= {DIV_W{1'b0}};
            if ((src_w == 16'd0) || (src_w > SRC_W_MAX) ||
                (src_h == 16'd0) || (src_h > SRC_H_MAX)) begin
                div_state <= DIV_IDLE;
            end else if ((src_w <= 16'd1) || (DST_W <= 1)) begin
                x_step <= {POS_W{1'b0}};
                x_center_start <= {POS_W{1'b0}};
                if ((src_h <= 16'd1) || (DST_H <= 1)) begin
                    y_step <= {POS_W{1'b0}};
                    y_center_start <= {POS_W{1'b0}};
                    step_ready <= 1'b1;
                    div_state <= DIV_IDLE;
                end else begin
                    if (src_h > DST_H_U16) begin
                        div_num <= {{(DIV_W-16){1'b0}}, src_h} << 16;
                        div_den <= DST_H;
                    end else begin
                        div_num <= {{(DIV_W-16){1'b0}}, (src_h - 16'd1)} << 16;
                        div_den <= DST_H - 1;
                    end
                    div_quot <= {DIV_W{1'b0}};
                    div_rem <= {DIV_DEN_W{1'b0}};
                    div_axis <= 1'b1;
                    div_bit <= DIV_W - 1;
                    div_state <= DIV_RUN;
                end
            end else begin
                if (src_w > DST_W_U16) begin
                    div_num <= {{(DIV_W-16){1'b0}}, src_w} << 16;
                    div_den <= DST_W;
                end else begin
                    div_num <= {{(DIV_W-16){1'b0}}, (src_w - 16'd1)} << 16;
                    div_den <= DST_W - 1;
                end
                div_quot <= {DIV_W{1'b0}};
                div_rem <= {DIV_DEN_W{1'b0}};
                div_axis <= 1'b0;
                div_bit <= DIV_W - 1;
                div_state <= DIV_RUN;
            end
        end else if (div_state == DIV_RUN) begin
            div_rem <= div_rem_next;
            div_quot <= div_quot_next;
            if (div_bit == 5'd0) begin
                if (!div_axis) begin
                    x_step <= div_quot_next;
                    if (src_w > DST_W_U16)
                        x_center_start <= (div_quot_next >> 1) - HALF_PIXEL_Q;
                    else
                        x_center_start <= {POS_W{1'b0}};

                    if ((src_h <= 16'd1) || (DST_H <= 1)) begin
                        y_step <= {POS_W{1'b0}};
                        y_center_start <= {POS_W{1'b0}};
                        step_ready <= 1'b1;
                        div_state <= DIV_IDLE;
                    end else begin
                        if (src_h > DST_H_U16) begin
                        div_num <= {{(DIV_W-16){1'b0}}, src_h} << 16;
                            div_den <= DST_H;
                        end else begin
                        div_num <= {{(DIV_W-16){1'b0}}, (src_h - 16'd1)} << 16;
                            div_den <= DST_H - 1;
                        end
                        div_quot <= {DIV_W{1'b0}};
                        div_rem <= {DIV_DEN_W{1'b0}};
                        div_axis <= 1'b1;
                        div_bit <= DIV_W - 1;
                    end
                end else begin
                    y_step <= div_quot_next;
                    if (src_h > DST_H_U16)
                        y_center_start <= (div_quot_next >> 1) - HALF_PIXEL_Q;
                    else
                        y_center_start <= {POS_W{1'b0}};
                    step_ready <= 1'b1;
                    div_state <= DIV_IDLE;
                end
            end else begin
                div_bit <= div_bit - 5'd1;
            end
        end
    end

    // One owner drives the output coordinates and FSM. `done` is asserted in
    // the same cycle as the final output pixel, then the engine returns idle.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            active <= 1'b0;
            coord_loaded <= 1'b0;
            state <= S_WAIT;
            dst_x <= {DST_X_W{1'b0}};
            dst_y <= {DST_Y_W{1'b0}};
            x_acc <= {POS_W{1'b0}};
            y_acc <= {POS_W{1'b0}};
            src_w_latched <= {SRC_W_COUNT_W{1'b0}};
            src_h_latched <= {SRC_H_COUNT_W{1'b0}};
            protect_y0 <= {SRC_H_COUNT_W{1'b0}};
            protect_y1 <= {SRC_H_COUNT_W{1'b0}};
            protection_valid <= 1'b0;
            protection_pending <= 1'b0;
            y0_match_q <= 3'b000;
            y1_match_q <= 3'b000;
            sample00 <= 24'd0; sample01 <= 24'd0;
            sample10 <= 24'd0; sample11 <= 24'd0;
            horizontal0 <= 24'd0; horizontal1 <= 24'd0;
            out_valid <= 1'b0;
            out_pixel <= 24'd0;
            done <= 1'b0;
            x0_sel <= {SRC_X_ADDR_W{1'b0}}; x1_sel <= {SRC_X_ADDR_W{1'b0}};
            y0_sel <= {SRC_H_COUNT_W{1'b0}}; y1_sel <= {SRC_H_COUNT_W{1'b0}};
            y0_bank_sel <= 2'd0; y1_bank_sel <= 2'd0;
            wx_raw_sel <= 16'd0; wy_raw_sel <= 16'd0;
            phase_knot_q <= 16'd0;
            phase_raw_q <= 16'd0;
            phase_product_q <= 27'd0;
            phase_enable_q <= 1'b0;
        end else if (start) begin
            src_w_latched <= src_w[SRC_W_COUNT_W-1:0];
            src_h_latched <= src_h[SRC_H_COUNT_W-1:0];
            protect_y0 <= {SRC_H_COUNT_W{1'b0}};
            protect_y1 <= {SRC_H_COUNT_W{1'b0}};
            protection_valid <= 1'b0;
            protection_pending <= 1'b0;
            y0_match_q <= 3'b000;
            y1_match_q <= 3'b000;
            active <= (src_w != 16'd0) && (src_w <= SRC_W_MAX) &&
                      (src_h != 16'd0) && (src_h <= SRC_H_MAX);
            coord_loaded <= 1'b0;
            state <= S_WAIT;
            dst_x <= {DST_X_W{1'b0}};
            dst_y <= {DST_Y_W{1'b0}};
            x_acc <= {POS_W{1'b0}};
            y_acc <= {POS_W{1'b0}};
            x0_sel <= {SRC_X_ADDR_W{1'b0}}; x1_sel <= {SRC_X_ADDR_W{1'b0}};
            y0_sel <= {SRC_H_COUNT_W{1'b0}}; y1_sel <= {SRC_H_COUNT_W{1'b0}};
            y0_bank_sel <= 2'd0; y1_bank_sel <= 2'd0;
            wx_raw_sel <= 16'd0; wy_raw_sel <= 16'd0;
            phase_knot_q <= 16'd0;
            phase_raw_q <= 16'd0;
            phase_product_q <= 27'd0;
            phase_enable_q <= 1'b0;
            out_valid <= 1'b0;
            done <= 1'b0;
        end else begin
            out_valid <= 1'b0;
            done <= 1'b0;

            if (step_ready && !coord_loaded) begin
                x_acc <= x_center_start;
                y_acc <= y_center_start;
                coord_loaded <= 1'b1;
            end
            if (coord_loaded && !protection_valid) begin
                if (!protection_pending) begin
                    protect_y0 <= y0;
                    protect_y1 <= y1;
                    protection_pending <= 1'b1;
                end else begin
                    // Conflict registers have now sampled the new protected row pair.
                    protection_valid <= 1'b1;
                    protection_pending <= 1'b0;
                end
            end

            case (state)
                S_WAIT: begin
                    if (active && coord_loaded) begin
                        x0_sel <= x0[SRC_X_ADDR_W-1:0];
                        x1_sel <= x1[SRC_X_ADDR_W-1:0];
                        y0_sel <= y0;
                        y1_sel <= y1;
                        wx_raw_sel <= wx_raw;
                        wy_raw_sel <= wy_raw;
                        state <= S_WAIT_ROWS;
                    end
                end
                S_WAIT_ROWS: begin
                    y0_match_q <= y0_match;
                    y1_match_q <= y1_match;
                    state <= S_CHECK_ROWS;
                end
                S_CHECK_ROWS: begin
                    if (y0_found_q && y1_found_q) begin
                        y0_bank_sel <= y0_bank_from_match;
                        y1_bank_sel <= y1_bank_from_match;
                        state <= S_PHASE_X;
                    end else begin
                        state <= S_WAIT_ROWS;
                    end
                end
                S_PHASE_X: begin
                    phase_knot_q <= phase_knot;
                    phase_raw_q <= phase_input;
                    phase_product_q <= phase_product;
                    phase_enable_q <= phase_axis_enable;
                    state <= S_PHASE_X_ADD;
                end
                S_PHASE_X_ADD: begin
                    state <= S_PHASE_Y;
                end
                S_PHASE_Y: begin
                    phase_knot_q <= phase_knot;
                    phase_raw_q <= phase_input;
                    phase_product_q <= phase_product;
                    phase_enable_q <= phase_axis_enable;
                    state <= S_PHASE_Y_ADD;
                end
                S_PHASE_Y_ADD: begin
                    state <= S_READ_X0;
                end
                S_READ_X0: state <= S_LATCH_X0;
                S_LATCH_X0: begin
                    sample00 <= row0_pixel_q;
                    sample01 <= row1_pixel_q;
                    state <= S_READ_X1;
                end
                S_READ_X1: state <= S_LATCH_X1;
                S_LATCH_X1: begin
                    sample10 <= row0_pixel_q;
                    sample11 <= row1_pixel_q;
                    state <= S_MIX_H;
                end
                S_MIX_H: state <= S_MIX_H_ADD;
                S_MIX_H_ADD: begin
                    if (x0_sel == x1_sel) begin
                        horizontal0 <= sample00;
                        horizontal1 <= sample01;
                    end else begin
                        horizontal0 <= mix_finish_rgb(sample00,h_products0);
                        horizontal1 <= mix_finish_rgb(sample01,h_products1);
                    end
                    state <= S_MIX_V;
                end
                S_MIX_V: state <= S_MIX_V_ADD;
                S_MIX_V_ADD: begin
                    if (y0_sel == y1_sel)
                        mixed_pixel <= horizontal0;
                    else
                        mixed_pixel <= mix_finish_rgb(horizontal0,v_products);
                    state <= S_EMIT;
                end
                S_EMIT: begin
                    out_pixel <= mixed_pixel;
                    out_valid <= 1'b1;
                    done <= (dst_x == DST_W-1) && (dst_y == DST_H-1);
                    state <= S_ADVANCE;
                end
                S_ADVANCE: begin
                    if (dst_x == DST_W-1) begin
                        dst_x <= {DST_X_W{1'b0}};
                        x_acc <= x_center_start;
                        if (dst_y == DST_H-1) begin
                            active <= 1'b0;
                            state <= S_WAIT;
                        end else begin
                            dst_y <= dst_y + {{(DST_Y_W-1){1'b0}},1'b1};
                            y_acc <= y_acc + y_step;
                            protection_valid <= 1'b0;
                            protection_pending <= 1'b0;
                            state <= S_WAIT;
                        end
                    end else begin
                        dst_x <= dst_x + {{(DST_X_W-1){1'b0}},1'b1};
                        x_acc <= x_acc + x_step;
                        state <= S_WAIT;
                    end
                end
                default: state <= S_WAIT;
            endcase
        end
    end
endmodule


// Latched fast-slide dwell, paused with the picture controller.
module photo_fast_dwell #(
    parameter integer CLK_FREQ_HZ = 100_000_000,
    parameter integer DWELL_MS    = 2000
)(
    input  wire clk,
    input  wire rst,
    input  wire clear,      // 单拍：新图上屏 / 切入快速轮播
    input  wire enable,     // fast_cycle_en
    input  wire paused,     // pause_sync1
    output reg  expired
);

    // 100 MHz / 1000 * 2000 = 200_000_000 拍，正好 2.000 s。
    //
    // ★ 必须拆成两级计数。单级 32 位计数器 + 32 位减法比较在 100MHz 下会被
    //   综合成"32 位进位链 + 32 位 ADDER(减法) + 归约"，实测把 sd_card_clk 域的
    //   违例端点从 31 拉到 167（这个域本来就只剩 −0.8ns 余量）。
    //   拆成 LO(200us) × HI 两级后，最长组合链只是 15 位进位 + 15 位等值比较。
    //   2000ms 时 LO_STEPS=20000、HI_STEPS=10000，乘积正好 200_000_000。
    //   注意：LO_STEPS 必须 <= DWELL_CYCLES（否则 HI 段永远数不到），
    //   调整 DWELL_MS 时请保证 (CLK_FREQ_HZ/1000)*DWELL_MS >= 20000。
    localparam integer DWELL_CYCLES = (CLK_FREQ_HZ / 1000) * DWELL_MS;
    localparam integer LO_STEPS     = 20000;
    localparam integer HI_STEPS     = (DWELL_CYCLES + LO_STEPS - 1) / LO_STEPS;

    localparam [14:0] LO_LAST = LO_STEPS - 1;
    localparam [13:0] HI_LAST = HI_STEPS - 1;

    reg [14:0] cnt_lo;
    reg [13:0] cnt_hi;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            cnt_lo  <= 15'd0;
            cnt_hi  <= 14'd0;
            expired <= 1'b0;
        end else if (clear || !enable) begin
            // 非快速模式常清，避免从别的模式切进来时带着旧的到期标志。
            cnt_lo  <= 15'd0;
            cnt_hi  <= 14'd0;
            expired <= 1'b0;
        end else if (!paused) begin
            if (cnt_lo == LO_LAST) begin
                cnt_lo <= 15'd0;
                if (cnt_hi == HI_LAST)
                    expired <= 1'b1;
                else
                    cnt_hi <= cnt_hi + 14'd1;
            end else begin
                cnt_lo <= cnt_lo + 15'd1;
            end
        end
    end

endmodule
