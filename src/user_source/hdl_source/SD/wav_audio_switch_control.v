module wav_audio_switch_control (
    input wire menu_hold,
    input  wire       rst_all,
    input  wire       image_load_busy,
    input  wire       track_start,
    input  wire       audio_done_pulse,
    input  wire       auto_play_en,
    input  wire       pause_state_control,
    input  wire       fast_mode,
    input  wire       fast_enter_pulse,
    input  wire [8:0] wav_fifo_wrusedw,
    output wire       wav_start,
    output wire       audio_fifo_rst,
    output wire       wav_fifo_allow_sector
);

    // Keep the current WAV stream alive during off-screen photo loading.
    // A committed photo still resets playback and starts its paired WAV.
    assign audio_fifo_rst = rst_all | (track_start & ~fast_mode) | fast_enter_pulse;
    assign wav_fifo_allow_sector = (wav_fifo_wrusedw < 9'd256);
    assign wav_start = (track_start & ~fast_mode) ||
                       (audio_done_pulse && !auto_play_en && !fast_mode &&
                        !image_load_busy && !pause_state_control && !menu_hold);

endmodule
