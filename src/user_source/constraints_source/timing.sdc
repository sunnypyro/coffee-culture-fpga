
# ============================================================
# merged_top_tf_hdmi_audio.sdc
# 用于：TF 图片轮播 + HDMI(视频+音频) 整合工程
#
# 合并原则：
# 1) 保留 top.sdc 里的系统主时钟与 derive_clocks
# 2) 把 timing(2).sdc 里的 pixel/serial 时钟改成整合工程实际名字
# 3) 增加 hdmi_5x_clk / audio_mclk 的命名
# 4) 不再对内部 net 直接 create_clock，避免和 derive_clocks 重复
# ============================================================

# ------------------------------------------------------------
# 1. 板级输入主时钟
#    你的原 top.sdc 里 clk=50MHz，所以这里仍然用 20ns
# ------------------------------------------------------------
create_clock -name clk -period 20 -waveform {0 10} [get_ports {clk}]

# ------------------------------------------------------------
# 2. 自动推导 PLL 输出时钟
# ------------------------------------------------------------
derive_clocks

# ------------------------------------------------------------
# 3. 给关键 PLL 输出命名
#    下面这些路径是按你当前工程实例名写的：
#      sys_pll      -> sys_pll_m0
#      video_pll    -> video_pll_m0
#      音频 PLL     -> u_audio_pll
#
#    如果综合后实例路径略有不同，就按 Timing Analyzer 里的实际 pin 路径改。
# ------------------------------------------------------------
rename_clock -name {sd_card_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {ext_mem_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {sys_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {video_clk}   -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[0]}]
rename_clock -name {hdmi_5x_clk} -source [get_ports {clk}] -master_clock {clk} [get_pins {video_pll_m0/pll_inst.clkc[1]}]
rename_clock -name {audio_mclk}  -source [get_ports {clk}] -master_clock {clk} [get_pins {u_audio_pll/pll_inst.clkc[2]}]

# ------------------------------------------------------------
# 4. 从原 timing(2).sdc 迁移过来的 HDMI 像素/串行时钟约束
#
#    原文件是：
#      create_clock -name pixel_clk  ... [get_nets {S_pixel_clk}]
#      create_clock -name serial_clk ... [get_nets {S_serial_clk}]
#      set_clock_groups -exclusive ...
#
#    在整合工程里，这两个时钟已经由 video_pll 产生，并通过 derive_clocks 建出来了，
#    所以这里只保留“组关系”，不再重复 create_clock。
#
#    这里沿用原作者的写法，把 video_clk 和 hdmi_5x_clk 设成 exclusive。
#    如果后面 Timing Analyzer 明确显示两者之间需要做同步时序分析，再把这一条去掉。
# ------------------------------------------------------------
set_clock_groups -exclusive \
    -group [get_clocks {video_clk}] \
    -group [get_clocks {hdmi_5x_clk}]

# ------------------------------------------------------------
# 5. 音频 I2S 发生器/接收器跨域
#
#    audio_mclk 域里生成 I2S，video_clk 域里做三拍同步采样。
#    这类路径不是普通同步时序路径，直接切掉更合理。
# ------------------------------------------------------------
set_clock_groups -asynchronous \
    -group [get_clocks {audio_mclk}] \
    -group [get_clocks {video_clk} hdmi_5x_clk sd_card_clk ext_mem_clk]

# ------------------------------------------------------------
# 6. 可选：如果你的 frame_read_write 内部异步 FIFO 已经完全处理好了跨域，
#    且报告里总出现 video_clk / sd_card_clk / ext_mem_clk 之间的大量伪违例，
#    可以打开下面这组异步分组。
#
#    建议先不要开，先看报告；
#    只有确认这些跨域都只经过 FIFO / 同步器时再开。
# ------------------------------------------------------------
# set_clock_groups -asynchronous \
#     -group [get_clocks {sd_card_clk}] \
#     -group [get_clocks {ext_mem_clk}] \
#     -group [get_clocks {video_clk}] \
#     -group [get_clocks {hdmi_5x_clk}]

# ------------------------------------------------------------
# 7. 其余 Input/Output delay 先保持空白
#    你当前两个原始 sdc 也都没有写这部分。
# ------------------------------------------------------------

# ------------------------------------------------------------
# 8. 音频通路 FIFO 的跨时钟域豁免（2026-09-13 新增）
#
#    背景：帧通路的两个软 FIFO（rfifo_32_32_512 / wfifo_32_32_512）
#    由软 FIFO IP 自带的 .tcl 经 IpSDCList 做了跨域豁免，所以它们的
#    格雷码指针同步器从来不会出现保持时间违例。
#
#    音频通路的 wav_fifo_16_512 是普通 Verilog 模块（不走 IP 流程），
#    内部有结构完全相同的格雷码同步器，但没有被豁免，结果在报告里出现：
#      Path Group : audio_mclk -> sd_card_clk   （SWNS -0.318ns）
#      以及大量 -1200ps ~ -1540ps 的保持时间违例与强制插缓冲。
#
#    这里按软 FIFO IP 完全相同的写法统一豁免：
#    datapath_only 表示只约束数据路径传播上限、不做保持检查。
# ------------------------------------------------------------
set_max_delay -datapath_only -from [get_regs -nowarn {*/primary_addr_gray_reg[*]}] -to [get_regs -nowarn {*/sync_r1[*]}] 999.7 -nowarn

# ------------------------------------------------------------
# 9. audio_mclk 与 sd_card_clk 之间的整段跨域路径豁免
#
#    这两个时钟都由 50MHz 主时钟经 PLL 产生，TD 把它们判为
#    "Same Domain"，因此第 5 节的 set_clock_groups -asynchronous
#    对这一对时钟不生效（报告里能看到 audio_mclk -> sd_card_clk 路径组）。
#
#    本设计里这两个时钟域之间的信号都是规范处理的：
#      - 音频采样数据：经 wav_fifo_16_512（格雷码指针 + 双端口 RAM）
#      - 播放结束标志：playback_done 经两级同步器 playback_done_sync
#      - 复位：异步复位，并在各自时钟域内做同步释放
#    因此这里按跨时钟域设计的标准做法，切掉这两个域之间的时序分析。
# ------------------------------------------------------------
set_false_path -from [get_clocks {audio_mclk}] -to [get_clocks {sd_card_clk}]
set_false_path -from [get_clocks {sd_card_clk}] -to [get_clocks {audio_mclk}]

# ------------------------------------------------------------
# 10. F06: independently resolve each audited synchronizer FIRST stage.
# TD resolves get_regs through the Q net, not the synthesized cell label.
# Use the runtime-supported SDC getters; -o is rejected by this TD parser.
# TD SWUG200: -datapath_only with -from also excludes hold on that entry.
# This is ONLY the metastability-catching stage. Subsequent stages stay timed.
# The SDRAM DQ/shifted-clock interface constraints above remain unchanged.
# ------------------------------------------------------------
set f06_cdc_read_req [get_regs {frame_read_write_m0/u_picker_scanout/req_sync[0]}]
if {[llength $f06_cdc_read_req] == 0} {
    error "F06 CDC read_req: no first-stage register matched; inspect Q-net names."
}
puts "F06 CDC read_req: $f06_cdc_read_req"
set_max_delay -from [get_clocks {video_clk}] -to [get_regs {frame_read_write_m0/u_picker_scanout/req_sync[0]}] -datapath_only 8.000

set f06_cdc_read_index [get_regs {frame_read_write_m0/u_picker_scanout/norm_sync[0]}]
if {[llength $f06_cdc_read_index] == 0} {
    error "F06 CDC read_index: no first-stage register matched; inspect Q-net names."
}
puts "F06 CDC read_index: $f06_cdc_read_index"
set_max_delay -from [get_clocks {video_clk}] -to [get_regs {frame_read_write_m0/u_picker_scanout/norm_sync[0]}] -datapath_only 8.000

set f06_cdc_display_ready [get_regs {u_display_control/ready0}]
if {[llength $f06_cdc_display_ready] == 0} {
    error "F06 CDC display_ready: no first-stage register matched; inspect Q-net names."
}
puts "F06 CDC display_ready: $f06_cdc_display_ready"
set_max_delay -from [get_clocks {video_clk}] -to [get_regs {u_display_control/ready0}] -datapath_only 8.000

set f06_cdc_panel_start [get_regs {u_hub75_scene/boot_start_sync[0]}]
if {[llength $f06_cdc_panel_start] == 0} {
    error "F06 CDC panel_start: no first-stage register matched; inspect Q-net names."
}
puts "F06 CDC panel_start: $f06_cdc_panel_start"
set_max_delay -from [get_clocks {video_clk}] -to [get_regs {u_hub75_scene/boot_start_sync[0]}] -datapath_only 8.000

set f06_cdc_panel_ready [get_regs {u_hub75_scene/ready_sync[0]}]
if {[llength $f06_cdc_panel_ready] == 0} {
    error "F06 CDC panel_ready: no first-stage register matched; inspect Q-net names."
}
puts "F06 CDC panel_ready: $f06_cdc_panel_ready"
set_max_delay -from [get_clocks {video_clk}] -to [get_regs {u_hub75_scene/ready_sync[0]}] -datapath_only 8.000

# This asynchronous first stage has zero Max Paths in this TD report, but
# datapath_only still excludes its hold check. Controlled same-DB comparison
# confirms HWNS -1.106 -> +0.024 ns with no setup change. Do not infer no-op
# from the Max table alone, or extend this exception past the first stage.
set f06_cdc_transition_ack [get_regs {sd_card_bmp_m0/ack_sync0}]
if {[llength $f06_cdc_transition_ack] == 0} {
    error "F06 CDC transition_ack: no first-stage register matched."
}
puts "F06 CDC transition_ack: $f06_cdc_transition_ack"
set_max_delay -from [get_clocks {video_clk}] -to [get_regs {sd_card_bmp_m0/ack_sync0}] -datapath_only 8.000

set f06_cdc_tail_vsync [get_regs {sd_card_bmp_m0/u_audio_tail_frame_wait/vsync_meta}]
if {[llength $f06_cdc_tail_vsync] == 0} {
    error "F06 CDC tail_vsync: no first-stage register matched; inspect Q-net names."
}
puts "F06 CDC tail_vsync: $f06_cdc_tail_vsync"
set_max_delay -from [get_clocks {video_clk}] -to [get_regs {sd_card_bmp_m0/u_audio_tail_frame_wait/vsync_meta}] -datapath_only 8.000

set f06_cdc_audio_pause [get_regs {u_pcm_i2s_player/pause_sync0}]
if {[llength $f06_cdc_audio_pause] == 0} {
    error "F06 CDC audio_pause: no first-stage register matched; inspect Q-net names."
}
puts "F06 CDC audio_pause: $f06_cdc_audio_pause"
set_max_delay -from [get_clocks {clk}] -to [get_regs {u_pcm_i2s_player/pause_sync0}] -datapath_only 8.000

set f06_cdc_sd_pause [get_regs {sd_card_bmp_m0/pause_sync0}]
if {[llength $f06_cdc_sd_pause] == 0} {
    error "F06 CDC sd_pause: no first-stage register matched; inspect Q-net names."
}
puts "F06 CDC sd_pause: $f06_cdc_sd_pause"
set_max_delay -from [get_clocks {clk}] -to [get_regs {sd_card_bmp_m0/pause_sync0}] -datapath_only 8.000

set f06_cdc_write_ack [get_regs {sd_card_bmp_m0/write_ack_meta}]
if {[llength $f06_cdc_write_ack] == 0} {
    error "F06 CDC write_ack: no first-stage register matched; inspect Q-net names."
}
puts "F06 CDC write_ack: $f06_cdc_write_ack"
set_max_delay -from [get_clocks {ext_mem_clk}] -to [get_regs {sd_card_bmp_m0/write_ack_meta}] -datapath_only 8.000

# Pause used in the SD-clock WAV restart decision is synchronized at top level.
set f06_cdc_wav_pause [get_regs {wav_pause_meta}]
if {[llength $f06_cdc_wav_pause] == 0} {
    error "F06 CDC wav_pause: no first-stage register matched."
}
puts "F06 CDC wav_pause: $f06_cdc_wav_pause"
set_max_delay -from [get_clocks {clk}] -to [get_regs {wav_pause_meta}] -datapath_only 8.000

# ------------------------------------------------------------
# 11. Native same-clock hold checks remain enabled. Replace the previous
# source-to-entire-clock 0.5 ns requirements with 0.05 ns margin ONLY on
# reported short register-to-BRAM pin paths. Existing route fix_hold stays on.
# Wildcard synthesized BRAM suffixes; do not bind to a placement-specific ID.
# No clock uncertainty change, blanket false path, or encrypted-IP edit.
# ------------------------------------------------------------
set f06_hdmi_data_to [get_pins {u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_island_data_gen/U_audio_sample_packet_2_channel/u_w96_d1024_fifo/u_logic_ramfifo*.dia*}]
puts "F06 hold hdmi_data targets: $f06_hdmi_data_to"
set_min_delay -from [get_clocks {video_clk}] -to [get_pins {u_hdmi_1_4b_transmitter_core_wrapper/u_hdmi_tx_controller_wrapper/u_hdmi_island_data_gen/U_audio_sample_packet_2_channel/u_w96_d1024_fifo/u_logic_ramfifo*.dia*}] 0.050

set f06_write_fifo_addr_to [get_pins {frame_read_write_m0/write_buf/ram_inst/ramread*.addra*}]
puts "F06 hold write_fifo_addr targets: $f06_write_fifo_addr_to"
set_min_delay -from [get_clocks {sd_card_clk}] -to [get_pins {frame_read_write_m0/write_buf/ram_inst/ramread*.addra*}] 0.050

set f06_scaler_data_to [get_pins {sd_card_bmp_m0/u_img_scaler/u_source_row*.dia*}]
puts "F06 hold scaler_data targets: $f06_scaler_data_to"
set_min_delay -from [get_clocks {sd_card_clk}] -to [get_pins {sd_card_bmp_m0/u_img_scaler/u_source_row*.dia*}] 0.050

# F11 passive source observers: bundled-data mailbox, held through ack.
# A payload is registered together with request; two request synchronizer
# stages precede destination capture. Keep the complete payload propagation
# below one 50MHz cycle (20ns), less than the 40ns control qualification.
# datapath_only removes unrelated clock-phase hold checks on this handshake,
# while retaining a real upper propagation bound. No downstream stage is cut.
set f11_voice_bus [get_regs {u_panel_media/u_voice/snapshot[*]}]
set f11_music_bus [get_regs {u_panel_media/u_music/snapshot[*]}]
if {[llength $f11_voice_bus] != 23 || [llength $f11_music_bus] != 23} {
    error "F11 mailbox bus endpoints changed; audit all payload bits before compiling."
}
puts "F11 voice mailbox bits: [llength $f11_voice_bus]"
puts "F11 music mailbox bits: [llength $f11_music_bus]"
set_max_delay -from [get_clocks {audio_mclk}] -to [get_regs {u_panel_media/u_voice/snapshot[*]}] -datapath_only 20.000
set_max_delay -from [get_clocks {video_clk}] -to [get_regs {u_panel_media/u_music/snapshot[*]}] -datapath_only 20.000

# Only the metastability-catching first stage of request/ack is asynchronous.
foreach f11_first {{u_panel_media/u_voice/request_sync[0]} {u_panel_media/u_music/request_sync[0]} {u_panel_media/u_voice/ack_sync[0]} {u_panel_media/u_music/ack_sync[0]}} {
    if {[llength [get_regs $f11_first]] != 1} {
        error "F11 handshake synchronizer first stage missing: $f11_first"
    }
}
set_max_delay -from [get_clocks {audio_mclk}] -to [get_regs {u_panel_media/u_voice/request_sync[0]}] -datapath_only 8.000
set_max_delay -from [get_clocks {video_clk}] -to [get_regs {u_panel_media/u_music/request_sync[0]}] -datapath_only 8.000
set_max_delay -from [get_clocks {clk}] -to [get_regs {u_panel_media/u_voice/ack_sync[0]}] -datapath_only 8.000
set_max_delay -from [get_clocks {clk}] -to [get_regs {u_panel_media/u_music/ack_sync[0]}] -datapath_only 8.000

# Four-grid picker: explicit SDC commands (TD does not expand custom proc calls).
set_max_delay -from [get_regs {u_picker_command_mailbox/request}] -to [get_regs {u_picker_command_mailbox/request_sync[0]}] -datapath_only 10.0
set_max_delay -from [get_regs {u_picker_command_mailbox/ack}] -to [get_regs {u_picker_command_mailbox/ack_sync[0]}] -datapath_only 10.0
set_max_delay -from [get_regs {u_picker_command_mailbox/held_data[*]}] -to [get_regs {u_picker_command_mailbox/dst_data[*]}] -datapath_only 10.0
set_max_delay -from [get_regs {u_picker_status_mailbox/request}] -to [get_regs {u_picker_status_mailbox/request_sync[0]}] -datapath_only 10.0
set_max_delay -from [get_regs {u_picker_status_mailbox/ack}] -to [get_regs {u_picker_status_mailbox/ack_sync[0]}] -datapath_only 10.0
set_max_delay -from [get_regs {u_picker_status_mailbox/held_data[*]}] -to [get_regs {u_picker_status_mailbox/dst_data[*]}] -datapath_only 10.0
set_max_delay -from [get_regs {u_picker_view_mailbox/request}] -to [get_regs {u_picker_view_mailbox/request_sync[0]}] -datapath_only 10.0
set_max_delay -from [get_regs {u_picker_view_mailbox/ack}] -to [get_regs {u_picker_view_mailbox/ack_sync[0]}] -datapath_only 10.0
set_max_delay -from [get_regs {u_picker_view_mailbox/held_data[*]}] -to [get_regs {u_picker_view_mailbox/dst_data[*]}] -datapath_only 10.0
set_max_delay -from [get_regs {u_picker_result_mailbox/request}] -to [get_regs {u_picker_result_mailbox/request_sync[0]}] -datapath_only 10.0
set_max_delay -from [get_regs {u_picker_result_mailbox/ack}] -to [get_regs {u_picker_result_mailbox/ack_sync[0]}] -datapath_only 10.0
set_max_delay -from [get_regs {u_picker_result_mailbox/held_data[*]}] -to [get_regs {u_picker_result_mailbox/dst_data[*]}] -datapath_only 10.0
set_max_delay -from [get_regs {u_picker_metadata_mailbox/request}] -to [get_regs {u_picker_metadata_mailbox/request_sync[0]}] -datapath_only 10.0
set_max_delay -from [get_regs {u_picker_metadata_mailbox/ack}] -to [get_regs {u_picker_metadata_mailbox/ack_sync[0]}] -datapath_only 10.0
set_max_delay -from [get_regs {u_picker_metadata_mailbox/held_data[*]}] -to [get_regs {u_picker_metadata_mailbox/dst_data[*]}] -datapath_only 10.0
set_max_delay -from [get_regs {u_picker_rebase_mailbox/request}] -to [get_regs {u_picker_rebase_mailbox/request_sync[0]}] -datapath_only 10.0
set_max_delay -from [get_regs {u_picker_rebase_mailbox/ack}] -to [get_regs {u_picker_rebase_mailbox/ack_sync[0]}] -datapath_only 10.0
set_max_delay -from [get_regs {u_picker_rebase_mailbox/held_data[*]}] -to [get_regs {u_picker_rebase_mailbox/dst_data[*]}] -datapath_only 10.0
set_max_delay -from [get_regs {u_picker_panel_mailbox/request}] -to [get_regs {u_picker_panel_mailbox/request_sync[0]}] -datapath_only 10.0
set_max_delay -from [get_regs {u_picker_panel_mailbox/ack}] -to [get_regs {u_picker_panel_mailbox/ack_sync[0]}] -datapath_only 10.0
set_max_delay -from [get_regs {u_picker_panel_mailbox/held_data[*]}] -to [get_regs {u_picker_panel_mailbox/dst_data[*]}] -datapath_only 10.0
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_regs {pv_menu_sys[0]}] -datapath_only 10.0
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_regs {pv_body_sys[0]}] -datapath_only 10.0
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_regs {pv_enable_sys[0]}] -datapath_only 10.0
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_regs {pv_menu_video[0]}] -datapath_only 10.0
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_regs {pv_body_video[0]}] -datapath_only 10.0
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_regs {pv_feedback_video[0]}] -datapath_only 10.0
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_regs {pv_selecting_video[0]}] -datapath_only 10.0
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_regs {pv_target0[*]}] -datapath_only 10.0
set_max_delay -from [get_clocks {ext_mem_clk}] -to [get_regs {pv_source0[*]}] -datapath_only 24.0
set_max_delay -from [get_clocks {ext_mem_clk}] -to [get_regs {pv_active_sd0[*]}] -datapath_only 24.0
set_max_delay -from [get_clocks {ext_mem_clk}] -to [get_regs {frame_read_write_m0/bank_sync[0]}] -datapath_only 24.0
set_max_delay -from [get_clocks {video_clk}] -to [get_regs {pv_visible_sd[0]}] -datapath_only 10
set_max_delay -from [get_clocks {video_clk}] -to [get_regs {frame_read_write_m0/u_picker_scanout/visible_sync[0]}] -datapath_only 24
set_max_delay -from [get_clocks {video_clk}] -to [get_regs {frame_read_write_m0/u_picker_scanout/e0_sync[0]}] -datapath_only 24
set_max_delay -from [get_clocks {video_clk}] -to [get_regs {frame_read_write_m0/u_picker_scanout/e1_sync[0]}] -datapath_only 24
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_regs {frame_read_write_m0/u_picker_scanout/override_sync[0]}] -datapath_only 10
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_regs {frame_read_write_m0/frame_fifo_write_m0/thumb_sync[0]}] -datapath_only 10
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_regs {frame_read_write_m0/frame_fifo_write_m0/abort_sync[0]}] -datapath_only 10
set_max_delay -from [get_clocks {ext_mem_clk}] -to [get_regs {sd_card_bmp_m0/writer_abort_sync[0]}] -datapath_only 10
set_max_delay -from [get_clocks {video_clk}] -to [get_regs {sd_card_bmp_m0/display_ready_sync[0]}] -datapath_only 10
set_max_delay -from [get_clocks {audio_mclk}] -to [get_regs {sd_card_bmp_m0/hold_applied_sync[0]}] -datapath_only 10
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_regs {u_pcm_i2s_player/picker_hold_sync[0]}] -datapath_only 10
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_regs {u_video_transition_mask/entry_sync[0]}] -datapath_only 10
set_max_delay -from [get_clocks {audio_mclk}] -to [get_regs {panel_done_sync[0]}] -datapath_only 20
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_regs {panel_failed_tsync[0]}] -datapath_only 10
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_regs {frame_read_write_m0/frame_fifo_write_m0/write_len_d0[*]}] -datapath_only 10
set_max_delay -from [get_regs {sd_card_bmp_m0/u_picker_control/thumb_idx[*]}] -to [get_regs {frame_read_write_m0/frame_fifo_write_m0/tile_base_d0[*]}] -datapath_only 10
set_max_delay -from [get_regs {frame_read_write_m0/read_buf*/wr_to_rd_cross_inst/primary_addr_gray_reg[*]}] -to [get_regs {frame_read_write_m0/read_buf*/wr_to_rd_cross_inst/sync_r1[*]}] -datapath_only 24
set_max_delay -from [get_regs {frame_read_write_m0/read_buf*/rd_to_wr_cross_inst/primary_addr_gray_reg[*]}] -to [get_regs {frame_read_write_m0/read_buf*/rd_to_wr_cross_inst/sync_r1[*]}] -datapath_only 24

# Only asynchronous SET pins of the deliberate reset-release synchronizers.
# Data pins, inter-stage paths and every downstream recovery/removal check remain.
# Use logical registers: TD packs flops into cells named for unrelated logic,
# so a physical *_reg*.sr name can miss the intended qualifier after packing.
# Only the two raw reset-producing regs reach these destinations; no qualifier
# Q-to-D or qualifier-to-downstream recovery/removal path is excluded.
set_false_path -from [get_regs {u_picker_input/long_reset}] -to [get_regs {*release_pipe[*]}]
set_false_path -from [get_regs {u_picker_input/input_owned}] -to [get_regs {*release_pipe[*]}]
# The high-fanout MEM reset register may be duplicated during packing. Its
# clock is stable across those copies. Only async-reset qualifiers are targets;
# their D/shift paths originate in SD or PIX and remain normally timed.
set_max_delay -from [get_clocks {ext_mem_clk}] -to [get_regs {frame_read_write_m0/write_buf/asy_w_rst*}] -datapath_only 24.000
set_max_delay -from [get_clocks {ext_mem_clk}] -to [get_regs {frame_read_write_m0/u_read_reset/release_pipe[*]}] -datapath_only 24.000

# Three independent sticky FIFO observations enter the SYS domain here.
# Bound only the first synchronizer stages; stage 0 -> stage 1 stays timed.
set_max_delay -from [get_clocks {video_clk}] -to [get_regs {diagnostic_sync0[0]}] -datapath_only 20.000
set_max_delay -from [get_clocks {ext_mem_clk}] -to [get_regs {diagnostic_sync0[1]}] -datapath_only 24.000
set_max_delay -from [get_clocks {sd_card_clk}] -to [get_regs {diagnostic_sync0[2]}] -datapath_only 10.000
