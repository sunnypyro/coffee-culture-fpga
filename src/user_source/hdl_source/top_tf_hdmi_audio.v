
// ===============================================================
// HUB75 面板三段式画面驱动：以下 .vh 用 include 指令引入，
// 不单独登记为源文件（清单 .al 在 GUI 里会被旧列表覆盖，新加的 .v 条目会消失，
//  综合随即报 HDL-8007 black box）。include 进顶层以后，只要顶层在清单里，
//  这几个模块必然参与编译。
//   DISPLAY/hub75_scene.vh                -> hub75_scene_driver
//   DISPLAY/hub75_frame_store.vh          -> hub75_frame_store_delta
//   DISPLAY/assets/panel_img_delta_rom.vh -> panel_img_delta_rom
//   DISPLAY/assets/panel_font_rom.vh      -> panel_font_rom
// 路径基准：td_project 目录（与 .al 里 ../user_source/... 的写法一致）
// ===============================================================
`include "../user_source/hdl_source/DISPLAY/hub75_media_bridge.vh"
`include "../user_source/hdl_source/DISPLAY/hub75_timeline.vh"
`include "../user_source/hdl_source/DISPLAY/hub75_renderer.vh"
`include "../user_source/hdl_source/DISPLAY/assets/panel_style_rom.vh"
`include "../user_source/hdl_source/DISPLAY/assets/panel_envelope_rom.vh"
`include "../user_source/hdl_source/DISPLAY/assets/panel_control_rom.vh"
`include "../user_source/hdl_source/DISPLAY/hub75_scene.vh"
`include "../user_source/hdl_source/DISPLAY/hub75_frame_store.vh"
`include "../user_source/hdl_source/DISPLAY/assets/panel_img_delta_rom.vh"
`include "../user_source/hdl_source/DISPLAY/assets/panel_font_rom.vh"
`include "../user_source/hdl_source/STARTUP/startup_assets.vh"
`include "../user_source/hdl_source/STARTUP/startup_video.vh"
`include "../user_source/hdl_source/STARTUP/startup_audio.vh"

`include "../user_source/hdl_source/PICKER/picker_mailbox.vh"
`include "../user_source/hdl_source/PICKER/picker_reset_release.vh"
`include "../user_source/hdl_source/PICKER/picker_input.vh"
`include "../user_source/hdl_source/PICKER/picker_thumbnail.vh"
`include "../user_source/hdl_source/PICKER/picker_scanout.vh"
`include "../user_source/hdl_source/PICKER/picker_style.vh"
`include "../user_source/hdl_source/PICKER/picker_control.vh"

module top(
    input                       clk,
    input                       rst_n,
    input                       sw1_picker,
    // 板上按键（2026-09-21 按官方手册 + 开发板原理图核实，KEY 按下为低）：
    //   KEY1 = A2 = rst_n（复位）
    //   KEY2 = B2 = key2 -> 手动切下一张
    //   KEY3 = B1 = key3 -> 暂停/恢复；调节过程中为确认键
    //   KEY4 = C1 = key4 -> 自动/手动模式切换
    input                       key2,           // 板上 KEY2：手动下一张
    input                       key3,           // 板上 KEY3：暂停/确认
    input                       key4,           // 板上 KEY4：手动/自动
    // 板上拨动开关（拨上为 1）：

    //   SW2 = C7 = sw2_audio_vis -> BGM 频谱显示（1=显示）
    //   SW3 = C6 = sw3      -> 对比度
    //   SW4 = C5 = sw4      -> 亮度
    // H11 是蜂鸣器驱动脚（BUZZER 网络），不是开关输入。
    input                       sw3,            // SW3：对比度
    input                       sw4,            // SW4：亮度

    input                       sw2_audio_vis, // SW2/C7：上拨=显示音频可视化

    output [5:0]                seg_sel,
    output [7:0]                seg_data,

    // HDMI TMDS
    output                      HDMI_CLK_P,
    output                      HDMI_D2_P,
    output                      HDMI_D1_P,
    output                      HDMI_D0_P,

    // HDMI DDC
    output                      HDMI_DDC_SCL,
    inout                       HDMI_DDC_SDA,

    // TF card SPI
    output                      sd_ncs,
    output                      sd_dclk,
    output                      sd_mosi,
    input                       sd_miso,

    // ==== HUB75 RGB LED 点阵（Waveshare RGB-Matrix-P2.5-64x64，1/32 扫）====
    // 全部走板上 J1 点阵扩展座（原厂 16x16 点阵模块插座），这 14 根脚在本工程中此前完全空闲。
    // 已避开原厂标为 I2S 输入的 L14/F13/J13，将来接回板载 I2S 不会冲突。
    output                      HUB_R1,         // 上半 32 行 红
    output                      HUB_G1,         // 上半 32 行 绿
    output                      HUB_B1,         // 上半 32 行 蓝
    output                      HUB_R2,         // 下半 32 行 红
    output                      HUB_G2,         // 下半 32 行 绿
    output                      HUB_B2,         // 下半 32 行 蓝
    output [4:0]                HUB_ADDR,       // {E,D,C,B,A} 行地址
    output                      HUB_CLK,        // 移位时钟
    output                      HUB_LAT,        // 锁存脉冲
    output                      HUB_OE          // 输出使能（低有效）
);

parameter MEM_DATA_BITS = 32;
parameter ADDR_BITS     = 21;
parameter BUSRT_BITS    = 10;
parameter FRAME_PIXELS  = 24'd307200;   // 640*480
parameter BUF0_ADDR     = 24'd0;
parameter BUF1_ADDR     = FRAME_PIXELS;

// ================= 音画同步相关参数（本次新增） =================
// Compatibility parameter: enables the one-shot F06 hybrid startup music.
// The former repeated square-wave beep is no longer instantiated.
parameter BOOT_TONE_EN  = 1'b1;


// Four-grid picker: all new project inputs live in srcgg only.
// Distribute the raw reset driver locally without changing reset qualification.
// TD SWUG106 max_fanout: replicate equivalent combinational drivers as needed.
(* max_fanout = 24 *) wire rst_all;
wire rst_sys,rst_sd,rst_mem,rst_pix;
wire picker_key_reset,picker_input_owned,pk_cmd_valid,pk_cmd_ready;
wire[2:0]pk_cmd_kind,pk_normal_keys;wire[1:0]pk_cmd_idx;
wire pk_sd_cmd_valid;wire[4:0]pk_sd_cmd;
wire picker_menu_active,picker_body_hold,picker_select_enabled,picker_entry_quiesce;
wire picker_thumb,picker_abort,picker_write_abort_done,picker_img_inflight;
wire[20:0]picker_tile_base;
wire picker_view_send,picker_view_cancel,picker_view_ready;
wire[7:0]picker_view_id;wire[1:0]picker_view_source;
wire[15:0]picker_view_width,picker_view_height;wire[1:0]picker_view_img;
wire picker_closed_event,picker_selected_event,picker_feedback_wait,picker_selecting;
wire[1:0]picker_selected_idx,picker_selected_buf;
wire pv_mem_cmd_valid,pv_mem_cmd_accept,pv_mem_result_valid,pv_mem_result_ready;
wire[10:0]pv_mem_cmd;wire[7:0]pv_mem_result_id;
wire[1:0]pv_mem_result_code,pv_mem_result_source,pv_active_source;
wire pv_sd_result_valid;wire[11:0]pv_sd_result;
wire pv_view_ready,pv_meta_ready,pv_meta_valid;wire[43:0]pv_meta_data;
wire pv_rebase_valid;wire[2:0]pv_rebase_data;
wire pv_status_ready,pv_status_valid;wire[1:0]pv_status_data;reg[1:0]pv_status_pending;
wire pv_status_send=(pv_status_pending!=0)&&pv_status_ready;
reg[1:0]pv_menu_sys,pv_body_sys,pv_enable_sys;
reg[1:0]pv_menu_video,pv_body_video,pv_feedback_video,pv_selecting_video;
reg[1:0]pv_target0,pv_target1,pv_source0,pv_source1;
reg pv_visible_toggle;reg[2:0]pv_visible_sd;
reg[1:0]pv_active_sd0,pv_active_sd1;
wire pv_normal_visible;
reg pv_plain_video;reg[1:0]pv_style_video;reg pv_vs_seen,pv_frame_blank;
reg pv_meta_pending;reg[1:0]pv_pending_source,pv_pending_idx;
reg[15:0]pv_pending_width,pv_pending_height;
wire pv_meta_match;
wire pv_meta_apply=pv_meta_match&&pv_pending_source!=2;
wire hs_picker,vs_picker,de_picker;wire[23:0]rgb_picker;
wire picker_pause_applied;

wire Sdr_init_done;
wire Sdr_init_ref_vld;
wire Sdr_busy;

wire sd_card_clk;
wire ext_mem_clk;
wire ext_mem_clk_sft;
wire video_clk;
wire hdmi_5x_clk;

wire hs;
wire vs;
wire de;

wire [23:0] vout_data_raw;
wire [23:0] vout_data;
wire        display_valid;
wire        hs_osd;
wire        vs_osd;
wire        de_osd;
wire [23:0] vout_data_osd;
wire        hs_bar;
wire        vs_bar;
wire        de_bar;
wire [23:0] vout_data_bar;
wire        hs_spectrum;
wire        vs_spectrum;
wire        de_spectrum;
wire [23:0] vout_data_spectrum;
wire        hs_transition;
wire        vs_transition;
wire        de_transition;
wire [23:0] vout_data_transition;
wire        hs_startup, vs_startup, de_startup;
wire [23:0] vout_data_startup;
wire        display_ready;
wire        startup_started;
wire        hdmi_video_locked;
wire        subtitle_active_osd;
wire [4:0]  subtitle_id_osd;
wire [1:0]  subtitle_level_osd;
wire [7:0]  callout_on_osd;
wire [23:0] callout_alpha_osd;
wire [23:0] callout_talpha_osd;
wire [31:0] callout_grow_osd;
wire [5:0]  bgm_spectrum_raw_height_index;
wire [3:0]  bgm_spectrum_raw_height_value;
wire        bgm_spectrum_raw_height_valid;
wire        bgm_spectrum_raw_frame_ready;
wire [5:0]  bgm_spectrum_height_index;
wire [3:0]  bgm_spectrum_height_value;
wire        bgm_spectrum_height_valid;
wire        bgm_spectrum_clear;
wire        bgm_spectrum_frame_ready;
wire [3:0]  bgm_spectrum_pause_attenuation;

wire [3:0]  state_code;
wire [6:0]  seg_data_0;






wire        video_read_req;
wire        video_read_req_ack;
wire        video_read_en;
wire [31:0] video_read_data;

wire        sd_card_write_en;
wire [31:0] sd_card_write_data;
wire        sd_card_write_req;
wire        sd_card_write_req_ack;
wire        frame_write_finish;
reg         frame_write_toggle_mem;

wire [1:0]  write_buf_idx;
wire [1:0]  disp_buf_idx;
wire        display_commit_toggle;
wire        display_commit_req_toggle;
wire        display_commit_ack_toggle;
wire [15:0] sd_hdr_width;
wire [15:0] sd_hdr_height;
wire        sd_hdr_toggle;
wire [1:0]  current_img_idx;
wire        image_load_busy;
wire        track_start;
wire [1:0]  track_idx;
wire        auto_play_en;
wire        fast_cycle_en;
wire        fast_cycle_enter;
wire        pause_state_control;

wire        adjust_active_control;
wire [1:0]  active_param_control;
wire signed [4:0] brightness_level_control;
wire signed [4:0] contrast_level_control;

// TF-card sector clients: FAT32 directory, current image loader, and WAV reader.
wire        dir_sd_req;
wire [31:0] dir_sd_sector;
wire [7:0]  dir_sd_data;
wire        dir_sd_valid;
wire        dir_sd_end;
wire        img_sd_req;
wire [31:0] img_sd_sector;
wire [7:0]  img_sd_data;
wire        img_sd_valid;
wire        img_sd_end;
wire        wav_sd_req;
wire [31:0] wav_sd_sector;
wire [7:0]  wav_sd_data;
wire        wav_sd_valid;
wire        wav_sd_end;
wire        audio_mux_req;
wire [31:0] audio_mux_sector;
wire [7:0]  audio_mux_data;
wire        audio_mux_valid;
wire        audio_mux_end;
wire        phy_sd_req;
wire [31:0] phy_sd_sector;
wire [7:0]  phy_sd_data;
wire        phy_sd_valid;
wire        phy_sd_end;
wire        sd_init_done;

reg         fat_scan_started;
reg         media_ready;
wire        fat_scan_done;
wire        fat_scan_error;
wire [31:0] fat_start_sector;
wire [31:0] first_data_sector;
wire [7:0]  sectors_per_cluster;
wire [31:0] photo1_cluster, photo2_cluster, photo3_cluster, photo4_cluster;
wire [31:0] audio1_cluster, audio2_cluster, audio3_cluster, audio4_cluster;
wire [31:0] photo1_size, photo2_size, photo3_size, photo4_size;
wire [31:0] audio1_size, audio2_size, audio3_size, audio4_size;
wire [27:0] bgm_cluster;
// ------------------------------------------------------------------
// 图片起始扇区 = first_data_sector + (cluster - 2) * sectors_per_cluster
//
// 2026-10-23：由「四条组合 wire」改成三级流水。
//   原来写的是
//     wire [31:0] photoN_sector = first_data_sector + cluster_to_sector(...);
//   实测这条链在 sd_card_clk(100MHz) 上是一条 12.2ns 的路：
//     sectors_per_cluster(8 位，扇出 28~72) → 3 级 LUT 移位选择
//     → 一条 4.4ns 的跨模块长线 → 32 位进位加 → img_sector 寄存器
//   需求 10ns，超 2.5ns，且 cell 只占 31%、net 占 69%（纯布线问题）。
//   它恰好卡在 100MHz 边界上，过不过全看布线运气：同一份 RTL 换一次
//   布局流程，一次 −2.507ns、一次侥幸躲过。而 sd_card_clk 一旦违例，
//   读卡握手就会失败 —— 表现是画面卡在最后一张、切不了图，BGM 照放。
//
//   拆法（每级只剩一次运算，长线与扇出被寄存器隔断）：
//     第 1 级：cluster - 2，同时将 spc 译码并寄存 first_data_sector
//     第 2 级：(cluster - 2) << log2(spc)
//     第 3 级：first_data_sector + offset
//
//   安全性：cluster / spc / first_data_sector 都是 FAT 目录扫描完成之后的
//   静态量；下游 sd_card_bmp 只在 (!scan_kicked && bmp_ready && media_ready)
//   那一拍锁存 img_sector，比扫描完成晚得多，多 3 拍没有任何影响。
//   （注：sector_offset_shift 只做移位；cluster-2 已提到第 1 级，
//     所以原来的 cluster_to_sector 函数已删除，避免有人再把长链写回来。）
// ------------------------------------------------------------------
function [31:0] sector_offset_shift;
    input [31:0] offset;
    input [2:0] shift_amount;
    input valid_spc;
    begin
        sector_offset_shift = valid_spc ? (offset << shift_amount) : 32'd0;
    end
endfunction

reg [2:0] spc_shift_p1;
reg spc_valid_p1;
reg  [31:0] fds_p1;
reg  [31:0] cm2_p1_1, cm2_p1_2, cm2_p1_3, cm2_p1_4;
reg  [31:0] off_p2_1, off_p2_2, off_p2_3, off_p2_4;
reg  [31:0] photo1_sector, photo2_sector, photo3_sector, photo4_sector;

always @(posedge sd_card_clk) begin
    // ---- 第 1 级：减去 2 簇，并把两个静态量各自打一拍 ----
    // Decode before the four wide shifters; the stage count stays unchanged.
    // Parallel encoding avoids a priority cone on the wide shift controls.
    // Invalid geometries remain masked by spc_valid_p1 in the next stage.
    spc_valid_p1 <= (sectors_per_cluster==8'd1) || (sectors_per_cluster==8'd2) ||
        (sectors_per_cluster==8'd4) || (sectors_per_cluster==8'd8) ||
        (sectors_per_cluster==8'd16) || (sectors_per_cluster==8'd32) ||
        (sectors_per_cluster==8'd64) || (sectors_per_cluster==8'd128);
    spc_shift_p1 <= {
        |sectors_per_cluster[7:4],
        sectors_per_cluster[2]|sectors_per_cluster[3]|sectors_per_cluster[6]|sectors_per_cluster[7],
        sectors_per_cluster[1]|sectors_per_cluster[3]|sectors_per_cluster[5]|sectors_per_cluster[7]};
    fds_p1   <= first_data_sector;
    cm2_p1_1 <= photo1_cluster - 32'd2;
    cm2_p1_2 <= photo2_cluster - 32'd2;
    cm2_p1_3 <= photo3_cluster - 32'd2;
    cm2_p1_4 <= photo4_cluster - 32'd2;

    // ---- 第 2 级：按每簇扇区数左移 ----
    off_p2_1 <= sector_offset_shift(cm2_p1_1, spc_shift_p1, spc_valid_p1);
    off_p2_2 <= sector_offset_shift(cm2_p1_2, spc_shift_p1, spc_valid_p1);
    off_p2_3 <= sector_offset_shift(cm2_p1_3, spc_shift_p1, spc_valid_p1);
    off_p2_4 <= sector_offset_shift(cm2_p1_4, spc_shift_p1, spc_valid_p1);

    // ---- 第 3 级：加上数据区起点 ----
    photo1_sector <= fds_p1 + off_p2_1;
    photo2_sector <= fds_p1 + off_p2_2;
    photo3_sector <= fds_p1 + off_p2_3;
    photo4_sector <= fds_p1 + off_p2_4;
end

// 一组 = 一张图 + 一首对应的歌。卡上少任何一个文件（簇号为 0），
// 整组都视为不可用：既不显示那张图，也不放那首歌，播放顺序直接越过这一组。
wire group0_ok = (photo1_cluster != 32'd0) && (audio1_cluster != 32'd0);
wire group1_ok = (photo2_cluster != 32'd0) && (audio2_cluster != 32'd0);
wire group2_ok = (photo3_cluster != 32'd0) && (audio3_cluster != 32'd0);
wire group3_ok = (photo4_cluster != 32'd0) && (audio4_cluster != 32'd0);
// Static media fields settle before fat_scan_done. Register the validity
// reduction separately from the wide sector snapshot in the SD controller.
reg [3:0] group_ok_mask;
always @(posedge sd_card_clk)
    group_ok_mask <= {group3_ok, group2_ok, group1_ok, group0_ok};

// Picture-only availability for manual/fast modes; narration mode retains its pair mask.
wire [3:0] photo_ok_mask = {(photo4_cluster != 32'd0), (photo3_cluster != 32'd0),
                            (photo2_cluster != 32'd0), (photo1_cluster != 32'd0)};
reg [3:0] photo_ok_mask_q;
always @(posedge sd_card_clk or posedge rst_sd) begin
    if (rst_sd)
        photo_ok_mask_q <= 4'd0;
    else
        photo_ok_mask_q <= photo_ok_mask;
end


wire App_rd_en;
wire [ADDR_BITS-1:0] App_rd_addr;
wire Sdr_rd_en;
wire [MEM_DATA_BITS-1:0] Sdr_rd_dout;
wire App_wr_en;
wire [ADDR_BITS-1:0] App_wr_addr;
wire [MEM_DATA_BITS-1:0] App_wr_din;
wire [3:0] App_wr_dm;

wire hs_0;
wire vs_0;
wire de_0;

// HDMI 1.4b 音频发射相关
wire        audio_pll_lock;
wire        audio_mclk;
wire        audio_i2s_bclk;
wire        audio_i2s_lrck;
wire        audio_i2s_dout;
wire        wav_i2s_bclk;
wire        wav_i2s_lrck;
wire        wav_i2s_dout;
wire        wav_fifo_read;
wire        wav_playback_done;
wire [15:0] wav_fifo_dout;
wire        wav_fifo_empty;
wire        wav_fifo_full;
wire [8:0]  wav_fifo_wrusedw;
wire        wav_fifo_allow_sector;
wire        wav_sample_wr_en;
wire [15:0] wav_sample_wr_data;
wire        wav_file_eof;
wire        wav_format_error;
wire        audio_fifo_rst;
reg         wav_start;
wire        wav_start_raw;
reg         wav_pause_meta, wav_pause_sync;
wire        audio_done_pulse;
wire        wav_playback_start_toggle;
reg  [2:0]  playback_done_sync;
wire        audio_valid;
wire [23:0] audio_left_data;
wire [23:0] audio_right_data;
wire signed [23:0] bgm_music_left;
wire signed [23:0] bgm_music_right;
wire signed [23:0] audio_left_mixed;
wire signed [23:0] audio_right_mixed;
wire signed [23:0] voice_with_startup_left;
wire signed [23:0] voice_with_startup_right;
wire        bgm_available;
wire        panel_bgm_step;
wire        bgm_music_active;
wire        acr_valid;
wire [19:0] acr_cts;
wire [19:0] acr_n;

wire        axis_s_user;
wire        axis_s_valid;
wire        axis_s_last;
wire [23:0] axis_s_data;
wire        axis_s_ready;

wire        edid_trig;
wire        edid_valid;
wire [7:0]  edid_data;

wire [9:0]  tmds_ch0_data;
wire [9:0]  tmds_ch1_data;
wire [9:0]  tmds_ch2_data;
wire [9:0]  tmds_clk_data;

// 统一复位：TF 图像链路 + HDMI 音频链路

assign rst_all = picker_key_reset | ~audio_pll_lock;
picker_reset_release u_reset_sys(clk,rst_all,rst_sys);
picker_reset_release u_reset_sd(sd_card_clk,rst_all,rst_sd);
picker_reset_release u_reset_mem(ext_mem_clk,rst_all,rst_mem);
picker_reset_release u_reset_pix(video_clk,rst_all,rst_pix);

// HDMI core / pixel-timing reset: KEY1 does NOT reset these, so the monitor's
// TMDS link survives a reset. Only a PLL loss (power-up) resets them.
wire video_rst;
assign video_rst = ~audio_pll_lock;

// STARTUP_SYNC_BEGIN
// The transport remains alive across KEY1 and narration track changes.
wire tx_rst_pix;
picker_reset_release u_tx_reset_pix(video_clk,video_rst,tx_rst_pix);
wire startup_prepared;
wire pcm_content_ready;
wire voice_clear_pix;
picker_reset_release u_voice_clear_pix(video_clk,audio_fifo_rst,voice_clear_pix);
reg [1:0] pcm_ready_sync;
reg pcm_ready_seen_low;
reg [1:0] voice_flush_count;
reg voice_content_release;
always @(posedge video_clk or posedge voice_clear_pix) begin
    if(voice_clear_pix) begin
        pcm_ready_sync<=0;pcm_ready_seen_low<=0;
        voice_flush_count<=0;voice_content_release<=0;
    end else begin
        pcm_ready_sync<={pcm_ready_sync[0],pcm_content_ready};
        if(!pcm_ready_sync[1]) begin
            pcm_ready_seen_low<=1;voice_flush_count<=0;voice_content_release<=0;
        end else if(pcm_ready_seen_low && audio_valid && !voice_content_release) begin
            if(voice_flush_count==1) voice_content_release<=1;
            else voice_flush_count<=voice_flush_count+1'b1;
        end
    end
end

// Two ACR updates and a live sample cadence establish internal transport.
// This is not a monitor-visible or monitor-audible ready indication.
reg [14:0] audio_tick_age;
reg [1:0] acr_good_count;
wire audio_transport_ready=(acr_good_count==2) && (audio_tick_age<15'd24999);
always @(posedge video_clk or posedge tx_rst_pix) begin
    if(tx_rst_pix) begin audio_tick_age<=15'd24999;acr_good_count<=0;end
    else begin
        if(audio_valid) audio_tick_age<=0;
        else if(audio_tick_age<15'd24999) audio_tick_age<=audio_tick_age+1'b1;
        if(audio_tick_age==15'd24999) acr_good_count<=0;
        else if(acr_valid && acr_good_count<2) acr_good_count<=acr_good_count+1'b1;
    end
end

localparam [15:0] BOOT_WAIT_FRAMES = 16'd270; // 4.536 s candidate: measured small-screen cold wake ~4 s
reg        cold_boot_done;
reg        vs_boot_q;
reg [15:0] boot_wait_cnt;
wire       vs_boot_edge = (!vs_boot_q && vs_startup);
always @(posedge video_clk or posedge tx_rst_pix) begin
    if (tx_rst_pix) begin
        cold_boot_done <= 1'b0;
        vs_boot_q      <= 1'b0;
        boot_wait_cnt  <= 16'd0;
    end else begin
        vs_boot_q <= vs_startup;
        if (startup_started)
            cold_boot_done <= 1'b1;
        if(!hdmi_video_locked || !audio_transport_ready) begin
            boot_wait_cnt<=0;
            if(!startup_started) cold_boot_done<=0;
        end else if (cold_boot_done)
            boot_wait_cnt <= 0;
        else if (vs_boot_edge && boot_wait_cnt < BOOT_WAIT_FRAMES)
            boot_wait_cnt <= boot_wait_cnt + 1'b1;
    end
end
wire       boot_ready;
reg        boot_ready_q;
always @(posedge video_clk or posedge tx_rst_pix) begin
    if (tx_rst_pix)
        boot_ready_q <= 1'b0;
    else
        boot_ready_q <= !rst_pix && hdmi_video_locked && audio_transport_ready &&
            startup_prepared && voice_content_release &&
            (cold_boot_done || (boot_wait_cnt >= BOOT_WAIT_FRAMES));
end
assign boot_ready = boot_ready_q;
// STARTUP_SYNC_END

// ================= 音画同步（本次新增） =================
// display_valid 由 sd_card_bmp 在 sd_card_clk(100MHz) 域产生，
// 而画面选择与音频模式都在 video_clk(25MHz) 域使用。
// 这里打 2 拍把它同步过来，既消除了跨时钟域隐患，
// 也让"画面出现"和"音乐开始"由同一个信号驱动 —— 严格同时。
reg  display_valid_sync0;
reg  display_valid_sync1;
always @(posedge video_clk or posedge rst_pix) begin
    if (rst_pix) begin
        display_valid_sync0 <= 1'b0;
        display_valid_sync1 <= 1'b0;
    end else begin
        display_valid_sync0 <= display_valid;
        display_valid_sync1 <= display_valid_sync0;
    end
end

reg display_commit_sync0;
reg display_commit_sync1;
reg display_commit_seen_video;
reg display_image_seen_video;

// Hold the source dimensions with the frame they describe.  The SD domain
// holds the 16-bit bundle stable while hdr_toggle crosses through two flops.
reg        hdr_toggle_sync0;
reg        hdr_toggle_sync1;
reg        hdr_toggle_seen_video;
reg [15:0] res_pending_width;
reg [15:0] res_pending_height;
reg        res_pending_valid;
reg [15:0] res_width;
reg [15:0] res_height;
reg        res_active;
wire       res_header_event = (hdr_toggle_sync1 != hdr_toggle_seen_video);
wire       res_display_commit_event = display_valid_sync1 &&
    (!display_image_seen_video ||
     (display_commit_sync1 != display_commit_seen_video));
wire [1:0] adj_param_show;
wire       adj_bar_visible;

always @(posedge video_clk or posedge rst_pix) begin
    if (rst_pix) begin
        hdr_toggle_sync0       <= 1'b0;
        hdr_toggle_sync1       <= 1'b0;
        hdr_toggle_seen_video  <= 1'b0;
        res_pending_width      <= 16'd0;
        res_pending_height     <= 16'd0;
        res_pending_valid      <= 1'b0;
        res_width              <= 16'd0;
        res_height             <= 16'd0;
        res_active             <= 1'b0;
    end else begin
        hdr_toggle_sync0 <= sd_hdr_toggle;
        hdr_toggle_sync1 <= hdr_toggle_sync0;

        if (res_display_commit_event && res_pending_valid) begin
            res_width         <= res_pending_width;
            res_height        <= res_pending_height;
            res_active        <= 1'b1;
            res_pending_valid <= 1'b0;
        end

        if(pv_meta_apply)begin res_width<=pv_pending_width;res_height<=pv_pending_height;res_active<=1;res_pending_valid<=0;end
        if (res_header_event) begin
            hdr_toggle_seen_video <= hdr_toggle_sync1;
            res_pending_width     <= sd_hdr_width;
            res_pending_height    <= sd_hdr_height;
            res_pending_valid     <= 1'b1;
        end
    end
end

// The SD-domain buffer index is intentionally not sampled as a multi-bit bus.
// The first valid frame always uses buffer 0; each later committed frame swaps
// the local video-domain selector on the synchronized commit toggle.
reg display_buf_sel_video;
wire [1:0] disp_buf_idx_video = {1'b0, display_buf_sel_video};

always @(posedge video_clk or posedge rst_pix) begin
    if (rst_pix) begin
        display_commit_sync0    <= 1'b0;
        display_commit_sync1    <= 1'b0;
        display_commit_seen_video <= 1'b0;
        display_image_seen_video <= 1'b0;
        display_buf_sel_video   <= 1'b0;
    end else begin
        display_commit_sync0 <= display_commit_toggle;
        display_commit_sync1 <= display_commit_sync0;

        if (!display_valid_sync1) begin
            display_commit_seen_video <= display_commit_sync1;
            display_image_seen_video  <= 1'b0;
            display_buf_sel_video     <= 1'b0;
        end else if (!display_image_seen_video) begin
            display_commit_seen_video <= display_commit_sync1;
            display_image_seen_video  <= 1'b1;
            display_buf_sel_video     <= 1'b0;
        end else if (display_commit_sync1 != display_commit_seen_video) begin
            display_commit_seen_video <= display_commit_sync1;
            display_buf_sel_video     <= ~display_buf_sel_video;
        end
        if(pv_rebase_valid)display_buf_sel_video<=pv_rebase_data[2];
    end
end

// F06 replaces the old post-load 120-frame black warmup. SD loading runs
// concurrently; the final overlay below releases display_ready once, at VS,
// after the complete opening AND a committed first image. PCM retains sample 0.

display_control #(
    .DEBOUNCE_CYCLES (1_000_000),
    .RATE_CYCLES     (25_000_000)
) u_display_control (
    .clk              (clk),
    .rst              (rst_sys),
    .display_ready    (display_ready),
    // 物理 KEY3 = B1 = key3：暂停/恢复；调节过程中=确认
    .key_pause        (pk_normal_keys[1]),
    .control_hold(pv_menu_sys[1]),.select_resume(pv_status_valid&&pv_status_data[1]),
    .sw3_contrast     (sw3),
    .sw4_brightness   (sw4),
    // SW3/SW4 拨动即可直接开始对应调节，无需模式选择。

    .pause_state      (pause_state_control),

    .adjust_active    (adjust_active_control),
    .active_param     (active_param_control),
    .brightness_level (brightness_level_control),
    .contrast_level   (contrast_level_control)
);

// ============================================================================
// 控制量跨时钟域：clk(50MHz) 域 -> video_clk(25MHz) 域
// ----------------------------------------------------------------------------
// display_control 在 clk 域产出的这些量会被 video_clk 域直接使用（OSD 暂停、
// 亮度/对比度、调节条）。多比特总线（5 位电平、2 位参数）直接跨域采样，翻转时
// 可能被采到中间值（例：3->4 = 011->100）。这里用"载荷 + toggle"握手做一次
// 原子传递：clk 域只要有一位变化就翻转 toggle（载荷保持不动），video 域同步
// 3 拍后检测边沿、把 14 位整体锁存 —— 要么全是旧值，要么全是新值。
// 锁存后的值是寄存器输出，不进入视频合成组合链，因此不增加 video_clk 的时序压力。
//
// 位分配（必须与下面的切片一致，共 14 位）：
//   [13]    pause_state
//   [12]    adjust_active
//   [11:10] active_param
//   [9:5]   brightness_level
//   [4:0]   contrast_level
// ============================================================================
wire [13:0] ctrl_bus = {pause_state_control||pv_body_sys[1], adjust_active_control,
                        active_param_control, brightness_level_control,
                        contrast_level_control};

reg  [13:0] ctrl_bus_q;
reg         ctrl_toggle_clk;
always @(posedge clk or posedge rst_sys) begin
    if (rst_sys) begin
        ctrl_bus_q      <= 14'd0;
        ctrl_toggle_clk <= 1'b0;
    end else if (ctrl_bus != ctrl_bus_q) begin
        ctrl_bus_q      <= ctrl_bus;
        ctrl_toggle_clk <= ~ctrl_toggle_clk;
    end
end

reg        ctrl_tog_v0, ctrl_tog_v1, ctrl_tog_seen;
reg [13:0] ctrl_video;
wire       ctrl_update_video = ctrl_tog_v1 ^ ctrl_tog_seen;

always @(posedge video_clk or posedge rst_pix) begin
    if (rst_pix) begin
        ctrl_tog_v0     <= 1'b0;
        ctrl_tog_v1     <= 1'b0;
        ctrl_tog_seen   <= 1'b0;
        ctrl_video      <= 14'd0;
    end else begin
        ctrl_tog_v0     <= ctrl_toggle_clk;
        ctrl_tog_v1     <= ctrl_tog_v0;
        ctrl_tog_seen   <= ctrl_tog_v1;
        if (ctrl_update_video)
            ctrl_video <= ctrl_bus;
    end
end

wire               pause_state_video   = ctrl_video[13];
wire               adjust_active_video = ctrl_video[12];
wire [1:0]         active_param_video  = ctrl_video[11:10];
wire signed [4:0]  brightness_video    = ctrl_video[9:5];
wire signed [4:0]  contrast_video      = ctrl_video[4:0];

// OSD control CDC: track identity is bundled with a toggle, so the video
// domain never samples a raw multi-bit SD-card-domain pulse.
reg        track_start_toggle_sd;
reg        track_toggle_v0;
reg        track_toggle_v1;
reg        track_toggle_seen;
reg [1:0]  track_id_v0;
reg [1:0]  track_id_v1;
reg [1:0]  track_id_video;
wire       track_start_video = track_toggle_v1 ^ track_toggle_seen;

always @(posedge sd_card_clk or posedge rst_sd) begin
    if (rst_sd)
        track_start_toggle_sd <= 1'b0;
    else if (track_start)
        track_start_toggle_sd <= ~track_start_toggle_sd;
end

reg        playback_toggle_v0;
reg        playback_toggle_v1;
reg        playback_toggle_seen;
wire       playback_start_video = playback_toggle_v1 ^ playback_toggle_seen;

always @(posedge video_clk or posedge rst_pix) begin
    if (rst_pix) begin
        track_toggle_v0     <= 1'b0;
        track_toggle_v1     <= 1'b0;
        track_toggle_seen   <= 1'b0;
        track_id_v0         <= 2'd0;
        track_id_v1         <= 2'd0;
        track_id_video      <= 2'd0;
        playback_toggle_v0  <= 1'b0;
        playback_toggle_v1  <= 1'b0;
        playback_toggle_seen<= 1'b0;
    end else begin
        track_toggle_v0    <= track_start_toggle_sd;
        track_toggle_v1    <= track_toggle_v0;
        track_id_v0        <= track_idx;
        track_id_v1        <= track_id_v0;
        track_toggle_seen  <= track_toggle_v1;
        if (track_start_video)
            track_id_video <= track_id_v1;

        if(pv_meta_apply)track_id_video<=pv_pending_idx;
        playback_toggle_v0   <= wav_playback_start_toggle;
        playback_toggle_v1   <= playback_toggle_v0;
        playback_toggle_seen <= playback_toggle_v1;
    end
end

// FAT32 scan runs once after SD-card initialization.  media_ready is kept
// high afterwards so the existing image player starts only with named files,
// and it only comes up when at least ONE whole group (picture + its song) was
// found on the card.  With zero usable groups the player waits with the
// display dark; the "report which group is missing" behaviour is a separate,
// still undecided feature.
always @(posedge sd_card_clk or posedge rst_sd) begin
    if (rst_sd) begin
        fat_scan_started <= 1'b0;
        media_ready      <= 1'b0;
    end else begin
        if (!sd_init_done) begin
            fat_scan_started <= 1'b0;
            media_ready      <= 1'b0;
        end else if (!fat_scan_started)
            fat_scan_started <= 1'b1;
        if (fat_scan_done)
            media_ready <= (photo_ok_mask != 4'b0);
    end
end

always @(posedge sd_card_clk or posedge rst_sd) begin
    if (rst_sd)
        playback_done_sync <= 3'b000;
    else
        playback_done_sync <= {playback_done_sync[1:0], wav_playback_done};
end
// Edge detection uses the stable second/third synchronizer stages.
assign audio_done_pulse = playback_done_sync[1] & ~playback_done_sync[2];

// 歌的 WAV 头校验失败时（wav_format_error 会保持为高），这首歌永远不会有
// playback_done。把"格式错误"也同步成"这首歌结束"脉冲，让播放器跳过这一组
// 去放下一组，而不是停在当前画面上没有声音。
reg  [2:0]  wav_error_sync;
always @(posedge sd_card_clk or posedge rst_sd) begin
    if (rst_sd)
        wav_error_sync <= 3'b000;
    else
        wav_error_sync <= {wav_error_sync[1:0], wav_format_error};
end
wire audio_failed_pulse = wav_error_sync[0] & ~wav_error_sync[1];

// "切到下一组"的总触发：歌正常放完，或者这首歌坏了放不出来
wire track_advance = audio_done_pulse | audio_failed_pulse;

// 保持你原来的 TF / SDRAM / video 时钟
sys_pll sys_pll_m0(
    .refclk     (clk),
    .clk0_out   (sd_card_clk),
    .clk1_out   (ext_mem_clk),
    .clk2_out   (ext_mem_clk_sft),
    .reset      (1'b0)
);

video_pll video_pll_m0(
    .refclk     (clk),
    .clk0_out   (video_clk),
    .clk1_out   (hdmi_5x_clk),
    .reset      (1'b0)
);

// 复用你 I2S->HDMI 工程里的 PLL，只取 12.288MHz 音频主时钟
PLL_HDMI_AUDIO u_audio_pll(
    .refclk     (clk),
    .reset      (1'b0),
    .extlock    (audio_pll_lock),
    .clk0_out   (),
    .clk1_out   (),
    .clk2_out   (audio_mclk)
);

// mem_clk 域把 write_finish 单拍转成 toggle，供 sd_card_clk 域可靠同步
always @(posedge ext_mem_clk or posedge rst_mem) begin
    if (rst_mem)
        frame_write_toggle_mem <= 1'b0;
    else if (frame_write_finish)
        frame_write_toggle_mem <= ~frame_write_toggle_mem;
end

// ===================== TF FAT32 文件表、图片缓存与 WAV 读取 =====================
fat32_directory_scanner u_fat32_directory_scanner(
    .clk                (sd_card_clk),
    .rst                (rst_sd),
    .start              (sd_init_done && !fat_scan_started),
    .sd_read_req        (dir_sd_req),
    .sd_read_sector     (dir_sd_sector),
    .sd_read_data       (dir_sd_data),
    .sd_read_data_valid (dir_sd_valid),
    .sd_read_end        (dir_sd_end),
    .busy               (),
    .done               (fat_scan_done),
    .error              (fat_scan_error),
    .fat_start_sector   (fat_start_sector),
    .first_data_sector  (first_data_sector),
    .sectors_per_cluster(sectors_per_cluster),
    .photo1_cluster     (photo1_cluster), .photo2_cluster(photo2_cluster), .photo3_cluster(photo3_cluster), .photo4_cluster(photo4_cluster),
    .audio1_cluster     (audio1_cluster), .audio2_cluster(audio2_cluster), .audio3_cluster(audio3_cluster), .audio4_cluster(audio4_cluster),
    .photo1_size        (photo1_size), .photo2_size(photo2_size), .photo3_size(photo3_size), .photo4_size(photo4_size),
    .audio1_size        (audio1_size), .audio2_size(audio2_size), .audio3_size(audio3_size), .audio4_size(audio4_size),
    .bgm_cluster        (bgm_cluster)
);

sd_card_bmp #(
    .CLK_FREQ_HZ       (100_000_000),
    .SCAN_START_SECTOR (32'd0),
    .SCAN_MAX_SECTOR   (32'd131071),
    .SCAN_TARGET_COUNT (3'd4)
) sd_card_bmp_m0(
    .picker_cmd_valid(pk_sd_cmd_valid),.picker_cmd_kind(pk_sd_cmd[4:2]),.picker_cmd_idx(pk_sd_cmd[1:0]),
    .picker_display_ready(display_ready),.picker_normal_visible(pv_normal_visible),.picker_view_ready(picker_view_ready),
    .picker_result_valid(pv_sd_result_valid),.picker_result_id(pv_sd_result[11:4]),.picker_result_code(pv_sd_result[3:2]),
    .picker_writer_abort_done(picker_write_abort_done),.picker_img_inflight(picker_img_inflight),.picker_audio_need(audio_mux_req),.picker_hold_applied(picker_pause_applied),
    .picker_menu_active(picker_menu_active),.picker_body_hold(picker_body_hold),.picker_select_enabled(picker_select_enabled),.picker_entry_quiesce(picker_entry_quiesce),
    .picker_thumb(picker_thumb),.picker_abort(picker_abort),.picker_tile_base(picker_tile_base),
    .picker_view_send(picker_view_send),.picker_view_cancel(picker_view_cancel),.picker_view_id(picker_view_id),.picker_view_source(picker_view_source),
    .picker_view_width(picker_view_width),.picker_view_height(picker_view_height),.picker_view_img(picker_view_img),
    .picker_closed_event(picker_closed_event),.picker_selected_event(picker_selected_event),.picker_selected_idx(picker_selected_idx),.picker_selected_buf(picker_selected_buf),
    .picker_feedback_wait(picker_feedback_wait),.picker_selecting(picker_selecting),

    .clk               (sd_card_clk),
    .rst               (rst_sd),
    // 物理 KEY2 = B2 = key2：手动切下一张（原来错接成 key3）
    .key_next          (pk_normal_keys[0]),
    .key_auto          (pk_normal_keys[2]),
    .pause_state       (pause_state_control),
    .video_vsync_async (vs_bar),
    .media_ready       (media_ready),
    .photo1_sector     (photo1_sector),
    .photo2_sector     (photo2_sector),
    .photo3_sector     (photo3_sector),
    .photo4_sector     (photo4_sector),
    .group_ok_mask     (group_ok_mask),
    .fast_ok_mask      (photo_ok_mask_q),
    .audio_done        (track_advance),
    .audio_failed      (audio_failed_pulse),
    .state_code        (state_code),
    .bmp_width         (16'd640),
    .bmp_height        (16'd480),
    .hdr_width         (sd_hdr_width),
    .hdr_height        (sd_hdr_height),
    .hdr_toggle        (sd_hdr_toggle),
    .display_valid     (display_valid),

    .write_finish_toggle(frame_write_toggle_mem),
    .write_buf_idx     (write_buf_idx),
    .disp_buf_idx      (disp_buf_idx),
    .display_commit_toggle     (display_commit_toggle),
    .display_commit_req_toggle (display_commit_req_toggle),
    .display_commit_ack_toggle (display_commit_ack_toggle),
    .current_img_idx   (current_img_idx),
    .image_load_busy   (image_load_busy),
    .track_start       (track_start),
    .track_idx         (track_idx),
    .auto_play_en      (auto_play_en),
    .fast_cycle_en     (fast_cycle_en),

    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data),
    .sd_init_done      (sd_init_done),
    .sd_sec_read       (img_sd_req),
    .sd_sec_read_addr  (img_sd_sector),
    .sd_sec_read_data  (img_sd_data),
    .sd_sec_read_data_valid(img_sd_valid),
    .sd_sec_read_end   (img_sd_end)
);

// Clear narration once on entry; retain the registered WAV start/pause path.
reg fast_cycle_en_d;
always @(posedge sd_card_clk or posedge rst_sd) begin
    if (rst_sd)
        fast_cycle_en_d <= 1'b0;
    else
        fast_cycle_en_d <= fast_cycle_en;
end
assign fast_cycle_enter = fast_cycle_en & ~fast_cycle_en_d;

// The restart decision is consumed by the SD-clock reader. Synchronize the
// control-domain pause first, then register the start fanout separately from
// its mode/key/end-of-audio decode. Track metadata is stable before this pulse.
always @(posedge sd_card_clk or posedge rst_sd) begin
    if (rst_sd) begin
        wav_pause_meta <= 1'b0;
        wav_pause_sync <= 1'b0;
        wav_start <= 1'b0;
    end else begin
        wav_pause_meta <= pause_state_control;
        wav_pause_sync <= wav_pause_meta;
        wav_start <= wav_start_raw && !fast_cycle_en;
    end
end

// In manual mode a completed WAV restarts on the current picture.  In
// automatic mode it instead triggers the preserved "next image" path.
wav_audio_switch_control u_wav_audio_switch_control (
    .rst_all               (rst_sd),
    .image_load_busy       (image_load_busy),
    .track_start           (track_start),
    .audio_done_pulse      (audio_done_pulse),
    .auto_play_en          (auto_play_en),
    .pause_state_control   (wav_pause_sync),
    .menu_hold(picker_body_hold),
    .fast_mode             (fast_cycle_en),
    .fast_enter_pulse      (fast_cycle_enter),
    .wav_fifo_wrusedw      (wav_fifo_wrusedw),
    .wav_start             (wav_start_raw),
    .audio_fifo_rst        (audio_fifo_rst),
    .wav_fifo_allow_sector (wav_fifo_allow_sector)
);

wav_sector_reader u_wav_sector_reader(
    .clk                (sd_card_clk),
    .rst                (rst_sd),
    .start              (wav_start),
    .first_data_sector  (first_data_sector),
    .fat_start_sector   (fat_start_sector),
    .sectors_per_cluster(sectors_per_cluster),
    .file_first_cluster ((track_idx == 2'd0) ? audio1_cluster : (track_idx == 2'd1) ? audio2_cluster : (track_idx == 2'd2) ? audio3_cluster : audio4_cluster),
    .file_size          ((track_idx == 2'd0) ? audio1_size : (track_idx == 2'd1) ? audio2_size : (track_idx == 2'd2) ? audio3_size : audio4_size),
    .abort              (fast_cycle_en_d),
    .sd_read_req        (wav_sd_req),
    .sd_read_sector     (wav_sd_sector),
    .sd_read_data       (wav_sd_data),
    .sd_read_data_valid (wav_sd_valid),
    .sd_read_end        (wav_sd_end),
    .fifo_allow_sector  (wav_fifo_allow_sector),
    .sample_wr_en       (wav_sample_wr_en),
    .sample_wr_data     (wav_sample_wr_data),
    .file_eof           (wav_file_eof),
    .format_error       (wav_format_error)
);

audio_fifo_16 u_wav_fifo(
    .rst        (audio_fifo_rst),
    .clkw       (sd_card_clk),
    .clkr       (audio_mclk),
    .we         (wav_sample_wr_en),
    .di         (wav_sample_wr_data),
    .re         (wav_fifo_read),
    .dout       (wav_fifo_dout),
    .valid      (),
    .full_flag  (wav_fifo_full),
    .empty_flag (wav_fifo_empty),
    .afull      (),
    .aempty     (),
    .wrusedw    (wav_fifo_wrusedw),
    .rdusedw    ()
);

pcm_i2s_player #(
    // 诊断开关已关闭（2026-09-15 收尾）：恢复正常，播放卡里的音乐。
    // 置 1 时播放器会改播自己生成的测试音，用于分离"播放器输出通路"与"卡里数据"，
    // 正常使用/答辩时必须保持 0。
    .TEST_TONE_EN  (1'b0),
    .CONTINUOUS_TRANSPORT(1'b1)
) u_pcm_i2s_player(
    .mclk          (audio_mclk),
    .rst           (audio_fifo_rst),
    .transport_rst (video_rst),
    .content_ready (pcm_content_ready),
    .content_release(voice_content_release),
    .fifo_data     (wav_fifo_dout),
    .fifo_empty    (wav_fifo_empty),
    .source_eof    (wav_file_eof),
    .pause_state   (pause_state_control || !display_ready),
    .picker_hold_req(picker_body_hold),.pause_applied(picker_pause_applied),
    .fifo_read     (wav_fifo_read),
    .i2s_bclk      (wav_i2s_bclk),
    .i2s_lrck      (wav_i2s_lrck),
    .i2s_dout      (wav_i2s_dout),
    .playback_done (wav_playback_done),
    .playback_start_toggle(wav_playback_start_toggle)
);

// BGM has an independent FAT32 reader/FIFO. Image prefetch and WAV track
// starts do not reset that stream; only the playback branch is attenuated.
secret_base_bgm_audio_path u_secret_base_bgm_audio_path (
    .sd_clk              (sd_card_clk),
    .sample_clk          (video_clk),
    .rst                 (rst_all),
    .scan_done           (fat_scan_done),
    .first_data_sector   (first_data_sector),
    .fat_start_sector    (fat_start_sector),
    .sectors_per_cluster (sectors_per_cluster),
    .file_first_cluster  (bgm_cluster),
    .voice_req           (wav_sd_req),
    .voice_sector        (wav_sd_sector),
    .voice_data          (wav_sd_data),
    .voice_valid         (wav_sd_valid),
    .voice_end           (wav_sd_end),
    .aud_req             (audio_mux_req),
    .aud_sector          (audio_mux_sector),
    .aud_data            (audio_mux_data),
    .aud_valid           (audio_mux_valid),
    .aud_end             (audio_mux_end),
    .sample_tick         (audio_valid),
    .display_ready       (display_ready),
    .pause_state         (pause_state_control&&!pv_menu_sys[1]),
    .voice_left          (pv_body_video[1]?24'sd0:voice_with_startup_left),
    .voice_right         (pv_body_video[1]?24'sd0:voice_with_startup_right),
    .panel_bgm_step      (panel_bgm_step),
    .bgm_available       (bgm_available),
    .music_active        (bgm_music_active),
    .music_left          (bgm_music_left),
    .music_right         (bgm_music_right),
    .mixed_left          (audio_left_mixed),
    .mixed_right         (audio_right_mixed)
);

sd_sector_arbiter u_sd_sector_arbiter(
    .img_inflight(picker_img_inflight),
    .clk        (sd_card_clk), .rst(rst_sd),
    .dir_req    (dir_sd_req), .dir_sector(dir_sd_sector), .dir_data(dir_sd_data), .dir_valid(dir_sd_valid), .dir_end(dir_sd_end),
    .img_req    (img_sd_req), .img_sector(img_sd_sector), .img_data(img_sd_data), .img_valid(img_sd_valid), .img_end(img_sd_end),
    .aud_req    (audio_mux_req), .aud_sector(audio_mux_sector), .aud_data(audio_mux_data), .aud_valid(audio_mux_valid), .aud_end(audio_mux_end),
    .phy_req    (phy_sd_req), .phy_sector(phy_sd_sector), .phy_data(phy_sd_data), .phy_valid(phy_sd_valid), .phy_end(phy_sd_end)
);

sd_card_top u_sd_card_top(
    .clk                    (sd_card_clk),
    .rst                    (rst_sd),
    .SD_nCS                 (sd_ncs), .SD_DCLK(sd_dclk), .SD_MOSI(sd_mosi), .SD_MISO(sd_miso),
    .sd_init_done           (sd_init_done),
    .sd_sec_read            (phy_sd_req), .sd_sec_read_addr(phy_sd_sector),
    .sd_sec_read_data       (phy_sd_data), .sd_sec_read_data_valid(phy_sd_valid), .sd_sec_read_end(phy_sd_end),
    .sd_sec_write           (1'b0), .sd_sec_write_addr(32'd0), .sd_sec_write_data(8'd0),
    .sd_sec_write_data_req  (), .sd_sec_write_end()
);

// ===================== 数码管：单个位显示 SD/BMP 状态 =====================
// SD/BMP status stays on digit 5. Digit 4 is blank until a FIFO fault is latched.

seg_decoder seg_decoder_img(
    .bin_data          (state_code),
    .seg_data          (seg_data_0)
);

seg_scan seg_scan_m0(
    .clk               (clk),
    .rst_n             (!rst_sys),
    .seg_sel           (seg_sel),
    .seg_data          (seg_data),
    .seg_data_0        ({1'b1,7'b111_1111}),
    .seg_data_1        ({1'b1,7'b111_1111}),
    .seg_data_2        ({1'b1,7'b111_1111}),
    .seg_data_3        ({1'b1,7'b111_1111}),
    .seg_data_4        ({1'b1,(diagnostic_sync1==0 ? 7'b111_1111 : diagnostic_segments)}),
    .seg_data_5        ({1'b1,seg_data_0})
);

// ===================== 原图像时序与帧缓存 =====================
video_timing_data video_timing_data_m0(
    .video_clk         (video_clk),
    .rst               (video_rst),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0)
);

video_delay video_delay_m0(
    .video_clk         (video_clk),
    .rst               (video_rst),
    .read_en           (video_read_en),
    .read_data         (video_read_data[31:8]),
    .hs                (hs_0),
    .vs                (vs_0),
    .de                (de_0),
    .hs_r              (hs),
    .vs_r              (vs),
    .de_r              (de),
    .vout_data         (vout_data_raw)
);

// 首图提交前黑屏；提交后一直显示当前显示缓冲区内容
// （display_ready 已同步到 video_clk 域，用它替代原来直接使用 display_valid）
assign vout_data = display_ready ? vout_data_raw : 24'd0;

osd_controller u_osd_controller(
    .video_clk          (video_clk),
    .rst                (rst_pix),
    .vs_in              (vs),
    .display_valid      (display_ready),
    .track_id           (track_id_video),
    .track_start_video  (track_start_video),
    .playback_start_video(playback_start_video),
    .pause_state        (pause_state_video),
    .subtitle_active    (subtitle_active_osd),
    .subtitle_id        (subtitle_id_osd),
    .subtitle_level     (subtitle_level_osd),
    .callout_on         (callout_on_osd),
    .callout_alpha      (callout_alpha_osd),
    .callout_talpha     (callout_talpha_osd),
    .callout_grow       (callout_grow_osd)
);

wire diagnostic_underflow,diagnostic_read_overflow,diagnostic_write_overflow;
reg [2:0] diagnostic_sync0,diagnostic_sync1;
wire [6:0] diagnostic_segments;
always @(posedge clk or posedge rst_sys) begin
 if(rst_sys)begin diagnostic_sync0<=0;diagnostic_sync1<=0;end
 else begin diagnostic_sync0<={diagnostic_write_overflow,diagnostic_read_overflow,diagnostic_underflow};diagnostic_sync1<=diagnostic_sync0;end
end
seg_decoder u_diagnostic_decoder(.bin_data({1'b0,diagnostic_sync1}),.seg_data(diagnostic_segments));
wire step_transition_idle;
video_osd_overlay u_video_osd_overlay(
    .step_track_id(track_id_video),.step_pause(pause_state_video),
    .step_transition_idle(step_transition_idle),
    .picker_plain(pv_plain_video),.picker_grid_visible(pv_plain_video && pv_style_video[1]),
    .video_clk       (video_clk),
    .rst             (video_rst),
    .hs_in           (hs),
    .vs_in           (vs),
    .de_in           (de),
    .rgb_in          (vout_data),
    .display_valid   (display_ready),
    .auto_mode_async (auto_play_en),
    .fast_mode_async (fast_cycle_en),
    .brightness_level(brightness_video),
    .contrast_level  (contrast_video),
    .subtitle_active (subtitle_active_osd),
    .subtitle_id     (subtitle_id_osd),
    .subtitle_level  (subtitle_level_osd),
    .callout_on      (callout_on_osd),
    .callout_alpha   (callout_alpha_osd),
    .callout_talpha  (callout_talpha_osd),
    .callout_grow    (callout_grow_osd),
    .res_width       (res_width),
    .res_height      (res_height),
    .res_active      (res_active),
    .adj_param_show  (adj_param_show),
    .adj_bar_visible (adj_bar_visible),
    .hs_out          (hs_osd),
    .vs_out          (vs_osd),
    .de_out          (de_osd),
    .rgb_out         (vout_data_osd)
);

video_adjust_bar u_video_adjust_bar(
    .suppress_draw(pv_plain_video),
    .video_clk        (video_clk),
    .rst              (video_rst),
    .hs_in            (hs_osd),
    .vs_in            (vs_osd),
    .de_in            (de_osd),
    .rgb_in           (vout_data_osd),
    .adjust_active    (adjust_active_video),
    .active_param     (active_param_video),
    .brightness_level (brightness_video),
    .contrast_level   (contrast_video),
    .bar_visible      (adj_bar_visible),
    .param_out        (adj_param_show),
    .hs_out           (hs_bar),
    .vs_out           (vs_bar),
    .de_out           (de_bar),
    .rgb_out          (vout_data_bar)
);

video_bgm_spectrum_overlay u_video_bgm_spectrum_overlay(
    .suppress_draw(pv_plain_video),
    .video_clk             (video_clk),
    .rst                   (video_rst),
    .hs_in                 (hs_bar),
    .vs_in                 (vs_bar),
    .de_in                 (de_bar),
    .rgb_in                (vout_data_bar),
    .display_ready         (display_ready),
    .sw2_enable_async      (sw2_audio_vis),
    .pause_state            (pause_state_control),
    .pause_attenuation      (bgm_spectrum_pause_attenuation),
    .spectrum_frame_ready  (bgm_spectrum_frame_ready),
    .spectrum_height_valid (bgm_spectrum_height_valid),
    .spectrum_height_index (bgm_spectrum_height_index),
    .spectrum_height_value (bgm_spectrum_height_value),
    .spectrum_clear         (bgm_spectrum_clear),
    .hs_out                (hs_spectrum),
    .vs_out                (vs_spectrum),
    .de_out                (de_spectrum),
    .rgb_out               (vout_data_spectrum)
);

video_transition_mask u_video_transition_mask(
    .step_ui_idle(step_transition_idle),
    .picker_plain(pv_plain_video),.picker_entry_quiesce(picker_entry_quiesce),
    .video_clk                  (video_clk),
    .rst                        (video_rst),
    .hs_in                      (hs_spectrum),
    .vs_in                      (vs_spectrum),
    .de_in                      (de_spectrum),
    .rgb_in                     (vout_data_spectrum),
    .display_valid              (display_valid_sync1),
    .pause_state                (pause_state_video),
    .display_commit_req_toggle  (display_commit_req_toggle),
    .display_commit_ack_toggle  (display_commit_ack_toggle),
    .display_commit_toggle      (display_commit_toggle),
    .hs_out                     (hs_transition),
    .vs_out                     (vs_transition),
    .de_out                     (de_transition),
    .rgb_out                    (vout_data_transition)
);

frame_read_write #(
    .WRITE_V_FLIP     (1),
    .FRAME_WIDTH      (640),
    .FRAME_HEIGHT     (480)
) frame_read_write_m0(
    .diagnostic_display_ready(display_ready),.diagnostic_write_reset(rst_sd),.diagnostic_underflow(diagnostic_underflow),
    .diagnostic_read_overflow(diagnostic_read_overflow),.diagnostic_write_overflow(diagnostic_write_overflow),
    .picker_override(picker_menu_active),.picker_visible_toggle(pv_visible_toggle),
    .picker_cmd_valid(pv_mem_cmd_valid),.picker_cmd_cancel(pv_mem_cmd[10]),.picker_cmd_id(pv_mem_cmd[9:2]),.picker_cmd_source(pv_mem_cmd[1:0]),
    .picker_cmd_accept(pv_mem_cmd_accept),.picker_result_valid(pv_mem_result_valid),.picker_result_ready(pv_mem_result_ready),
    .picker_result_id(pv_mem_result_id),.picker_result_code(pv_mem_result_code),.picker_result_source(pv_mem_result_source),.picker_active_source(pv_active_source),
    .picker_thumb(picker_thumb),.picker_tile_base(picker_tile_base),.picker_write_abort(picker_abort),.picker_write_abort_done(picker_write_abort_done),
    .mem_clk           (ext_mem_clk),
    .rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),

    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout),

    .read_clk          (video_clk),
    .read_req          (video_read_req),
    .read_req_ack      (video_read_req_ack),
    .read_finish       (),
    .read_addr_0       (BUF0_ADDR),
    .read_addr_1       (BUF1_ADDR),
    .read_addr_2       (24'd0),
    .read_addr_3       (24'd0),
    .read_addr_index   (disp_buf_idx_video),
    .read_len          (FRAME_PIXELS),
    .read_en           (video_read_en),
    .read_data         (video_read_data),

    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_din        (App_wr_din),
    .App_wr_dm         (App_wr_dm),

    .write_clk         (sd_card_clk),
    .write_req         (sd_card_write_req),
    .write_req_ack     (sd_card_write_req_ack),
    .write_finish      (frame_write_finish),
    .write_addr_0      (BUF0_ADDR),
    .write_addr_1      (BUF1_ADDR),
    .write_addr_2      (24'd0),
    .write_addr_3      (24'd0),
    .write_addr_index  (write_buf_idx),
    .write_len         (picker_thumb ? 21'd76800 : 21'd307200),
    .write_en          (sd_card_write_en),
    .write_data        (sd_card_write_data)
);

sdram U3(
    .Clk               (ext_mem_clk),
    .Clk_sft           (ext_mem_clk_sft),
    .Rst               (rst_mem),
    .Sdr_init_done     (Sdr_init_done),
    .Sdr_init_ref_vld  (Sdr_init_ref_vld),
    .Sdr_busy          (Sdr_busy),
    .App_wr_en         (App_wr_en),
    .App_wr_addr       (App_wr_addr),
    .App_wr_dm         (App_wr_dm),
    .App_wr_din        (App_wr_din),
    .App_rd_en         (App_rd_en),
    .App_rd_addr       (App_rd_addr),
    .Sdr_rd_en         (Sdr_rd_en),
    .Sdr_rd_dout       (Sdr_rd_dout)
);

// Always use the existing PCM serializer clock. Its paused mode keeps I2S
// running without consuming the narration FIFO. Startup PCM is mixed after
// reception, so no asynchronous I2S source switch or second serializer exists.
assign audio_i2s_bclk = wav_i2s_bclk;
assign audio_i2s_lrck = wav_i2s_lrck;
assign audio_i2s_dout = wav_i2s_dout;

wire signed [23:0] startup_sample;
wire signed [23:0] startup_sample_enabled = BOOT_TONE_EN ? startup_sample : 24'sd0;
function signed [23:0] startup_add_pcm;
    input signed [23:0] voice_pcm, intro_pcm;
    reg signed [24:0] sum;
    begin
        sum={voice_pcm[23],voice_pcm}+{intro_pcm[23],intro_pcm};
        if (sum>25'sd8388607) startup_add_pcm=24'sh7fffff;
        else if (sum < -25'sd8388608) startup_add_pcm=24'sh800000;
        else startup_add_pcm=sum[23:0];
    end
endfunction
assign voice_with_startup_left = startup_add_pcm(voice_content_release ? audio_left_data : 24'd0,startup_sample_enabled);
assign voice_with_startup_right = startup_add_pcm(voice_content_release ? audio_right_data : 24'd0,startup_sample_enabled);
f06_startup_audio u_startup_audio (
    .clk(video_clk),.rst(rst_pix),.started(startup_started),
    .sample_tick(audio_valid),.sample_out(startup_sample),.prepared(startup_prepared));

I2S_receiver u_I2S_receiver(
    .I_clk              (video_clk),
    .I_rst              (rst_pix),
    .I_i2s_BCLK         (audio_i2s_bclk),
    .I_i2s_LRCK         (audio_i2s_lrck),
    .I_i2s_DOUT         (audio_i2s_dout),
    .O_audio_valid      (audio_valid),
    .O_audio_left_data  (audio_left_data),
    .O_audio_right_data (audio_right_data)
);

// Analyze the full-level BGM PCM tap, not the 5/8 playback branch or voice.
bgm_spectrum_analyzer u_bgm_spectrum_analyzer(
    .clk              (video_clk),
    .rst              (rst_pix),
    .sample_valid     (audio_valid),
    .music_active     (bgm_music_active),
    .pause_state      (pause_state_control),
    .bgm_sample       (bgm_music_left[23:16]),
    .height_index     (bgm_spectrum_raw_height_index),
    .height_value     (bgm_spectrum_raw_height_value),
    .height_valid     (bgm_spectrum_raw_height_valid),
    .frame_ready      (bgm_spectrum_raw_frame_ready),
    .spectrum_clear   (bgm_spectrum_clear)
);

video_bgm_spectrum_height_smoother u_bgm_spectrum_height_smoother(
    .clk                    (video_clk),
    .rst                    (rst_pix),
    .spectrum_clear         (bgm_spectrum_clear),
    .pause_state            (pause_state_control),
    .height_valid           (bgm_spectrum_raw_height_valid),
    .height_index           (bgm_spectrum_raw_height_index),
    .height_value           (bgm_spectrum_raw_height_value),
    .frame_ready            (bgm_spectrum_raw_frame_ready),
    .smoothed_height_valid  (bgm_spectrum_height_valid),
    .smoothed_height_index  (bgm_spectrum_height_index),
    .smoothed_height_value  (bgm_spectrum_height_value),
    .smoothed_frame_ready   (bgm_spectrum_frame_ready)
);

audio_arc_calculate #(
    .ACR_N         (6144)
) u_audio_arc_calculate (
    .I_clk         (video_clk),
    .I_rst         (tx_rst_pix),
    .I_audio_valid (audio_valid),
    .O_acr_valid   (acr_valid),
    .O_acr_cts     (acr_cts),
    .O_acr_n       (acr_n)
);

// Final overlay: OSD/spectrum/adjustment cannot leak into the opening.
// Begin at a prepared frame boundary after the common cold-boot settling gate.
f06_startup_video u_startup_video (
    .clk(video_clk),.rst(video_rst),.restart(rst_pix),
    .video_locked(hdmi_video_locked),
    .hs_in(hs_picker),.vs_in(vs_picker),.de_in(de_picker),
    .rgb_in(rgb_picker),.first_image_ready(display_valid_sync1),
    .boot_ready(boot_ready),
    .hs_out(hs_startup),.vs_out(vs_startup),.de_out(de_startup),
    .rgb_out(vout_data_startup),.display_ready(display_ready),.started(startup_started));

// ===================== RGB/DE 转 AXIS 视频 =====================
video_rgb_to_axis_640x480 u_video_rgb_to_axis_640x480(
    .I_clk         (video_clk),
    .I_rst         (video_rst),
    .I_vs          (vs_startup),
    .I_de          (de_startup),
    .I_rgb         (vout_data_startup),
    .O_video_user  (axis_s_user),
    .O_video_valid (axis_s_valid),
    .O_video_last  (axis_s_last),
    .O_video_data  (axis_s_data)
);

// 上电后自动打一拍，触发一次 EDID 读取
startup_pulse #(
    .CNT_MAX(20'd100000)
) u_startup_pulse (
    .I_clk   (video_clk),
    .I_rst   (tx_rst_pix),
    .O_pulse (edid_trig)
);

// ===================== 带音频的 HDMI 1.4b 发射 =====================
hdmi_1_4b_transmitter_core_wrapper #(
    .DEVICE                 ( "EG"       ),
    .HTOTAL                 ( 800        ),
    .HSA                    ( 96         ),
    .HFP                    ( 16         ),
    .HBP                    ( 48         ),
    .HACTIVE                ( 640        ),
    .VTOTAL                 ( 525        ),
    .VSA                    ( 2          ),
    .VFP                    ( 10         ),
    .VBP                    ( 33         ),
    .VACTIVE                ( 480        ),
    .VIDEO_VIC              ( 1          ),
    .VIDEO_TPG              ( "Disable"  ),
    .VIDEO_FORMAT           ( "RGB"      ),
    .AUDIO_SAMPLE_RATE      ( "48K"      ),
    .IIC_SCL_DIV            ( 250        )
) u_hdmi_1_4b_transmitter_core_wrapper(
    .I_pixel_clk        (video_clk),
    .I_rst              (video_rst),
    .I_edid_read_trig   (edid_trig),
    .O_edid_read_valid  (edid_valid),
    .O_edid_read_data   (edid_data),

    .I_axis_s_user      (axis_s_user),
    .I_axis_s_valid     (axis_s_valid),
    .I_axis_s_last      (axis_s_last),
    .I_axis_s_data      (axis_s_data),
    .O_axis_s_ready     (axis_s_ready),

    .I_audio_valid      (audio_valid),
    .I_audio_left_data  ((rst_pix || !startup_started) ? 24'd0 : audio_left_mixed),
    .I_audio_right_data ((rst_pix || !startup_started) ? 24'd0 : audio_right_mixed),
    .I_acr_valid        (acr_valid),
    .I_acr_cts          (acr_cts),
    .I_acr_n            (acr_n),

    .O_video_locked     (hdmi_video_locked),
    .O_ddc_scl          (HDMI_DDC_SCL),
    .IO_ddc_sda         (HDMI_DDC_SDA),

    .O_ch0_tmds_data    (tmds_ch0_data),
    .O_ch1_tmds_data    (tmds_ch1_data),
    .O_ch2_tmds_data    (tmds_ch2_data),
    .O_clk_tmds_data    (tmds_clk_data)
);

hdmi_phy_wrapper #(
    .DEVICE ( "EG" )
) u_hdmi2phy_wrapper(
    .I_pixel_clk        (video_clk),
    .I_serial_clk       (hdmi_5x_clk),
    .I_rst              (video_rst),
    .I_tmds_channel_0   (tmds_ch0_data),
    .I_tmds_channel_1   (tmds_ch1_data),
    .I_tmds_channel_2   (tmds_ch2_data),
    .I_tmds_channel_clk (tmds_clk_data),
    .O_tmds_ch0_p       (HDMI_D0_P),
    .O_tmds_ch1_p       (HDMI_D1_P),
    .O_tmds_ch2_p       (HDMI_D2_P),
    .O_tmds_clk_p       (HDMI_CLK_P)
);

// ===================== HUB75 点阵三段式画面（移植自 srcdian）=====================
// 完全独立于 HDMI / SD 通路：挂在 50 MHz 输入时钟 clk 上。
// 选 clk 而不是 sd_card_clk(100 MHz) 是刻意的 —— 同流程基线对照显示
// sd_card_clk 域本来就吃紧，把这里的逻辑挂过去会额外压出 30 多个违例端点；
// 而 clk 域余量较大。
//
// 画面（64x64）：y0..15 = 标题滚动字幕；y16..60 = 45x45 四段手冲动画；
//               y61..63 = 四段总进度条。
// 每通道 3bit（512 色）：一帧拆 3 个 BCM 子场，点亮时长权重 4:2:1。
// 面板每通道只有 1 根数据线，1bit 只能出 8 色，而这张图的主色是棕/橙/白，
// 8 色里没有任何棕色 —— 实测 8 色(含抖动)全部不可用，故必须上 BCM。

// ---- 音频组 -> 点阵动画（sd_card_clk 域 -> clk 域）----
// track_idx(0..3) 就是"当前第几组 PHOTO/AUDIO"，切组那一拍同时翻 track_start_toggle_sd。
// 跨域沿用已存在的 toggle：clk 域两级同步后看到跳变沿再采样数据，
// 属于标准的"数据先稳、toggle 后到"握手，不会采到半新半旧的组号。
reg        hub_tg0, hub_tg1, hub_tg_seen;
reg  [1:0] hub_track_id;
reg        hub_track_start;
reg [1:0] hub_fast_sync,hub_pause_sync;

always @(posedge clk or posedge rst_sys) begin
    if (rst_sys) begin
        hub_track_start<=0;hub_fast_sync<=0;hub_pause_sync<=0;
        hub_tg0      <= 1'b0;
        hub_tg1      <= 1'b0;
        hub_tg_seen  <= 1'b0;
        hub_track_id <= 2'd0;
    end else begin
        hub_track_start<=hub_tg1 ^ hub_tg_seen;
        hub_fast_sync<={hub_fast_sync[0],fast_cycle_en};
        hub_pause_sync<={hub_pause_sync[0],pause_state_control||pv_body_sys[1]};
        hub_tg0     <= track_start_toggle_sd;
        hub_tg1     <= hub_tg0;
        hub_tg_seen <= hub_tg1;
        if (hub_tg1 ^ hub_tg_seen)
            hub_track_id <= track_idx;
    end
end

wire panel_voice_epoch,panel_voice_active,panel_music_active,panel_snapshot_valid;
wire[1:0]panel_voice_track;wire[18:0]panel_voice_pos;wire[21:0]panel_music_pos;
hub75_media_bridge u_panel_media(audio_mclk,wav_fifo_read,wav_playback_start_toggle,wav_playback_done,track_idx,
 video_clk,panel_bgm_step,bgm_music_active,clk,rst_all,panel_voice_epoch,panel_voice_track,panel_voice_pos,
 panel_voice_active,panel_music_pos,panel_music_active,panel_snapshot_valid);


wire panel_picker_valid;wire[10:0]panel_picker_data;
picker_mailbox #(.WIDTH(11))u_picker_panel_mailbox(
 .src_clk(sd_card_clk),
 .src_rst(rst_sd),
 .src_send(picker_selected_event),
 .src_ready(),
 .src_data({picker_view_id,picker_selected_idx,1'b0}),
 .src_done(),
 .dst_clk(clk),
 .dst_rst(rst_sys),
 .dst_valid(panel_picker_valid),
 .dst_data(panel_picker_data),
 .dst_accept(1'b1)
);
reg panel_owned,panel_fast_hold,panel_release_ready,panel_commit_pulse;
reg[1:0]panel_track_hold;reg[3:0]panel_release_count;
reg[1:0]panel_done_sync,panel_failed_sync;reg panel_failed_toggle;
reg[1:0]panel_failed_tsync;reg panel_failed_seen,panel_failed_latched;
always @(posedge sd_card_clk or posedge rst_sd)begin
 if(rst_sd)panel_failed_toggle<=0;else if(audio_failed_pulse)panel_failed_toggle<=~panel_failed_toggle;
end
always @(posedge clk or posedge rst_sys)begin
 if(rst_sys)begin
  panel_owned<=0;panel_fast_hold<=0;panel_track_hold<=0;panel_release_count<=0;
  panel_release_ready<=0;panel_commit_pulse<=0;panel_done_sync<=0;
  panel_failed_tsync<=0;panel_failed_seen<=0;panel_failed_latched<=0;
 end else begin
  panel_done_sync<={panel_done_sync[0],wav_playback_done};
  panel_failed_tsync<={panel_failed_tsync[0],panel_failed_toggle};
  panel_commit_pulse<=0;
  if(panel_failed_tsync[1]!=panel_failed_seen)begin panel_failed_seen<=panel_failed_tsync[1];panel_failed_latched<=1;end
  if(pv_body_sys[1]&&!panel_owned)begin
   panel_owned<=1;panel_fast_hold<=hub_fast_sync[1];panel_track_hold<=hub_track_id;
   panel_release_ready<=0;panel_release_count<=0;
  end
  if(panel_picker_valid)begin
   panel_fast_hold<=panel_picker_data[0];panel_track_hold<=panel_picker_data[2:1];
   panel_commit_pulse<=1;panel_release_ready<=0;panel_release_count<=0;panel_failed_latched<=0;
  end
  if(panel_owned&&!pv_body_sys[1]&&!panel_picker_valid)begin
   if(panel_fast_hold||pause_state_control||panel_done_sync[1]||panel_failed_latched||
      (panel_voice_active&&panel_voice_track==panel_track_hold))panel_release_ready<=1;
   if(panel_release_ready&&hub_fast_sync[1]==panel_fast_hold&&hub_track_id==panel_track_hold&&!hub_track_start)begin
    if(panel_release_count==8)panel_owned<=0;else panel_release_count<=panel_release_count+1'b1;
   end else panel_release_count<=0;
  end
 end
end

hub75_scene_driver #(
    .DIV_W      (2),                 // 50 MHz / 4 = 12.5 MHz 移位时钟
    .TBASE      (12'd256)
) u_hub75_scene (
    .clk         (clk),
    .rst         (rst_sys),
    .track_id    (panel_owned?panel_track_hold:hub_track_id),
    .track_start (panel_owned?panel_commit_pulse:hub_track_start),
    .pause       (hub_pause_sync[1]||(panel_owned&&!panel_release_ready)),
    .fast_mode   (panel_owned?panel_fast_hold:hub_fast_sync[1]),
    .voice_epoch (panel_voice_epoch),.voice_track_q(panel_voice_track),.voice_pos(panel_voice_pos),
    .voice_active(panel_voice_active),.music_pos(panel_music_pos),.music_active(panel_music_active),.snapshot_valid(panel_snapshot_valid),
    .startup_started(startup_started),
    .playback_ready(display_ready),
    .HUB_R1      (HUB_R1),
    .HUB_G1      (HUB_G1),
    .HUB_B1      (HUB_B1),
    .HUB_R2      (HUB_R2),
    .HUB_G2      (HUB_G2),
    .HUB_B2      (HUB_B2),
    .HUB_ADDR    (HUB_ADDR),
    .HUB_CLK     (HUB_CLK),
    .HUB_LAT     (HUB_LAT),
    .HUB_OE      (HUB_OE)
);

assign pv_normal_visible=(pv_visible_sd[2]^pv_visible_sd[1])&&(pv_active_sd1==disp_buf_idx);
assign pv_meta_match=pv_meta_pending&&!de_0&&(pv_source1==pv_pending_source);
picker_input u_picker_input(
 .clk(clk),.power_rst(!audio_pll_lock),.soft_reset_active(rst_sys),.sw1(sw1_picker),
 .key_n({key4,key3,key2,rst_n}),.menu_select_enabled(pv_enable_sys[1]),
 .menu_closed_ack(pv_status_valid&&pv_status_data[0]),.cmd_ready(pk_cmd_ready),
 .cmd_valid(pk_cmd_valid),.cmd_kind(pk_cmd_kind),.cmd_idx(pk_cmd_idx),
 .input_owned(picker_input_owned),.key1_reset_req(picker_key_reset),.normal_keys_n(pk_normal_keys));
picker_mailbox #(.WIDTH(5))u_picker_command_mailbox(
 .src_clk(clk),
 .src_rst(rst_sys),
 .src_send(pk_cmd_valid),
 .src_ready(pk_cmd_ready),
 .src_data({pk_cmd_kind,pk_cmd_idx}),
 .src_done(),
 .dst_clk(sd_card_clk),
 .dst_rst(rst_sd),
 .dst_valid(pk_sd_cmd_valid),
 .dst_data(pk_sd_cmd),
 .dst_accept(1'b1)
);
always @(posedge sd_card_clk or posedge rst_sd)begin
 if(rst_sd)begin pv_status_pending<=0;pv_visible_sd<=0;pv_active_sd0<=0;pv_active_sd1<=0;end
 else begin
  if(pv_status_send)pv_status_pending<={picker_selected_event,picker_closed_event};
  else pv_status_pending<=pv_status_pending|{picker_selected_event,picker_closed_event};
  pv_visible_sd<={pv_visible_sd[1:0],pv_visible_toggle};
  pv_active_sd0<=pv_active_source;pv_active_sd1<=pv_active_sd0;
 end
end
picker_mailbox #(.WIDTH(2))u_picker_status_mailbox(
 .src_clk(sd_card_clk),
 .src_rst(rst_sd),
 .src_send(pv_status_send),
 .src_ready(pv_status_ready),
 .src_data(pv_status_pending),
 .src_done(),
 .dst_clk(clk),
 .dst_rst(rst_sys),
 .dst_valid(pv_status_valid),
 .dst_data(pv_status_data),
 .dst_accept(1'b1)
);
always @(posedge clk or posedge rst_sys)begin
 if(rst_sys)begin pv_menu_sys<=0;pv_body_sys<=0;pv_enable_sys<=0;end
 else begin
  pv_menu_sys<={pv_menu_sys[0],picker_menu_active};
  pv_body_sys<={pv_body_sys[0],picker_body_hold};pv_enable_sys<={pv_enable_sys[0],picker_select_enabled};
 end
end
assign picker_view_ready=pv_view_ready&&pv_meta_ready;
picker_mailbox #(.WIDTH(11))u_picker_view_mailbox(
 .src_clk(sd_card_clk),
 .src_rst(rst_sd),
 .src_send(picker_view_send),
 .src_ready(pv_view_ready),
 .src_data({picker_view_cancel,picker_view_id,picker_view_source}),
 .src_done(),
 .dst_clk(ext_mem_clk),
 .dst_rst(rst_mem),
 .dst_valid(pv_mem_cmd_valid),
 .dst_data(pv_mem_cmd),
 .dst_accept(pv_mem_cmd_accept)
);
picker_mailbox #(.WIDTH(12))u_picker_result_mailbox(
 .src_clk(ext_mem_clk),
 .src_rst(rst_mem),
 .src_send(pv_mem_result_valid),
 .src_ready(pv_mem_result_ready),
 .src_data({pv_mem_result_id,pv_mem_result_code,pv_mem_result_source}),
 .src_done(),
 .dst_clk(sd_card_clk),
 .dst_rst(rst_sd),
 .dst_valid(pv_sd_result_valid),
 .dst_data(pv_sd_result),
 .dst_accept(1'b1)
);
picker_mailbox #(.WIDTH(44))u_picker_metadata_mailbox(
 .src_clk(sd_card_clk),
 .src_rst(rst_sd),
 .src_send(picker_view_send&&!picker_view_cancel),
 .src_ready(pv_meta_ready),
 .src_data({picker_view_id,picker_view_source,picker_view_img,picker_view_width,picker_view_height}),
 .src_done(),
 .dst_clk(video_clk),
 .dst_rst(rst_pix),
 .dst_valid(pv_meta_valid),
 .dst_data(pv_meta_data),
 .dst_accept(1'b1)
);
picker_mailbox #(.WIDTH(3))u_picker_rebase_mailbox(
 .src_clk(sd_card_clk),
 .src_rst(rst_sd),
 .src_send(picker_selected_event),
 .src_ready(),
 .src_data({picker_selected_buf[0],picker_selected_idx}),
 .src_done(),
 .dst_clk(video_clk),
 .dst_rst(rst_pix),
 .dst_valid(pv_rebase_valid),
 .dst_data(pv_rebase_data),
 .dst_accept(1'b1)
);
always @(posedge video_clk or posedge rst_pix)begin
 if(rst_pix)begin
  pv_visible_toggle<=0;pv_menu_video<=0;pv_body_video<=0;pv_feedback_video<=0;pv_selecting_video<=0;
  pv_target0<=0;pv_target1<=0;pv_source0<=0;pv_source1<=0;pv_vs_seen<=0;pv_frame_blank<=0;
  pv_plain_video<=0;pv_style_video<=0;pv_meta_pending<=0;
  pv_pending_source<=0;pv_pending_idx<=0;pv_pending_width<=0;pv_pending_height<=0;
 end else begin
  if(axis_s_valid&&axis_s_user&&display_ready)pv_visible_toggle<=~pv_visible_toggle;
  pv_menu_video<={pv_menu_video[0],picker_menu_active};pv_body_video<={pv_body_video[0],picker_body_hold};
  pv_feedback_video<={pv_feedback_video[0],picker_feedback_wait};pv_selecting_video<={pv_selecting_video[0],picker_selecting};
  pv_target0<=picker_selected_idx;pv_target1<=pv_target0;pv_source0<=pv_active_source;pv_source1<=pv_source0;
  pv_vs_seen<=vs_0;
  if(pv_meta_match)pv_meta_pending<=0;
  if(pv_meta_valid)begin
   pv_meta_pending<=1;pv_pending_source<=pv_meta_data[35:34];pv_pending_idx<=pv_meta_data[33:32];
   pv_pending_width<=pv_meta_data[31:16];pv_pending_height<=pv_meta_data[15:0];
  end
  if(pv_vs_seen&&!vs_0)pv_frame_blank<=1;
  if(de_0)pv_frame_blank<=0;
  if((pv_frame_blank||(pv_vs_seen&&!vs_0))&&!de_0)begin
   pv_plain_video<=pv_menu_video[1];
   if(!pv_menu_video[1])pv_style_video<=0;
   else if(pv_source1==2)pv_style_video<=pv_selecting_video[1]&&pv_feedback_video[1]?3:2;
   else pv_style_video<=pv_feedback_video[1]&&!pv_selecting_video[1]?1:0;
  end
 end
end
picker_style u_picker_style(video_clk,video_rst,hs_transition,vs_transition,de_transition,vout_data_transition,
 pv_style_video,pv_target1,hs_picker,vs_picker,de_picker,rgb_picker);

endmodule
