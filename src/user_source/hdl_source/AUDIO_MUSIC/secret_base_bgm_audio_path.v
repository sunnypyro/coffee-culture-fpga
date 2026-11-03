// Joins the dedicated BGM WAV stream to the existing narration audio path.
// The narration keeps its own reader/FIFO; this module only shares the
// physical audio-sector slot and adds the background PCM at the sample output.
module secret_base_bgm_audio_path #(
    parameter [22:0] BGM_FILE_SIZE_BYTES = 23'd4_848_044
) (
    input  wire        sd_clk,
    input  wire        sample_clk,
    input  wire        rst,
    input  wire        scan_done,
    input  wire [31:0] first_data_sector,
    input  wire [31:0] fat_start_sector,
    input  wire [7:0]  sectors_per_cluster,
    input  wire [27:0] file_first_cluster,

    input  wire        voice_req,
    input  wire [31:0] voice_sector,
    output wire [7:0]  voice_data,
    output wire        voice_valid,
    output wire        voice_end,

    output wire        aud_req,
    output wire [31:0] aud_sector,
    input  wire [7:0]  aud_data,
    input  wire        aud_valid,
    input  wire        aud_end,

    input  wire        sample_tick,
    input  wire        display_ready,
    input  wire        pause_state,
    input  wire signed [23:0] voice_left,
    input  wire signed [23:0] voice_right,
    output wire        panel_bgm_step,
    output wire        bgm_available,
    output wire        music_active,
    output wire signed [23:0] music_left,
    output wire signed [23:0] music_right,
    output wire signed [23:0] mixed_left,
    output wire signed [23:0] mixed_right
);
    wire sd_reset,sample_reset;
    picker_reset_release u_sd_reset(sd_clk,rst,sd_reset);
    picker_reset_release u_sample_reset(sample_clk,rst,sample_reset);
    wire bgm_available_sd;
    wire bgm_req;
    wire [31:0] bgm_sector;
    wire [7:0] bgm_data;
    wire bgm_valid;
    wire bgm_end;
    wire bgm_sample_valid;
    assign panel_bgm_step = bgm_sample_valid;
    wire signed [15:0] bgm_sample;

    reg bgm_available_sync0;
    reg bgm_available_sync1;
    always @(posedge sample_clk or posedge sample_reset) begin
        if (sample_reset) begin
            bgm_available_sync0 <= 1'b0;
            bgm_available_sync1 <= 1'b0;
        end else begin
            bgm_available_sync0 <= bgm_available_sd;
            bgm_available_sync1 <= bgm_available_sync0;
        end
    end

    assign bgm_available = bgm_available_sync1;
    assign music_active = display_ready && bgm_available;

    secret_base_bgm_stream #(
        .FILE_SIZE_BYTES(BGM_FILE_SIZE_BYTES)
    ) u_bgm_stream (
        .sd_clk             (sd_clk),
        .sample_clk         (sample_clk),
        .rst                (sd_reset),
        .scan_done          (scan_done),
        .first_data_sector  (first_data_sector),
        .fat_start_sector   (fat_start_sector),
        .sectors_per_cluster(sectors_per_cluster),
        .file_first_cluster (file_first_cluster),
        .bgm_sd_req         (bgm_req),
        .bgm_sd_sector      (bgm_sector),
        .bgm_sd_data        (bgm_data),
        .bgm_sd_data_valid  (bgm_valid),
        .bgm_sd_end         (bgm_end),
        .sample_tick        (sample_tick),
        .playback_enable    (music_active),
        .pause_state        (pause_state),
        .bgm_available      (bgm_available_sd),
        .bgm_sample_valid   (bgm_sample_valid),
        .bgm_sample         (bgm_sample)
    );

    sd_audio_sector_mux u_audio_sector_mux (
        .clk         (sd_clk),
        .rst         (sd_reset),
        .voice_req   (voice_req),
        .voice_sector(voice_sector),
        .voice_data  (voice_data),
        .voice_valid (voice_valid),
        .voice_end   (voice_end),
        .bgm_req     (bgm_req),
        .bgm_sector  (bgm_sector),
        .bgm_data    (bgm_data),
        .bgm_valid   (bgm_valid),
        .bgm_end     (bgm_end),
        .aud_req     (aud_req),
        .aud_sector  (aud_sector),
        .aud_data    (aud_data),
        .aud_valid   (aud_valid),
        .aud_end     (aud_end)
    );

    secret_base_pcm_mixer u_pcm_mixer (
        .sample_valid    (sample_tick),
        .music_enable    (music_active),
        .pause_state     (pause_state),
        .bgm_sample_valid(bgm_sample_valid),
        .bgm_sample      (bgm_sample),
        .voice_left      (voice_left),
        .voice_right     (voice_right),
        .music_left      (music_left),
        .music_right     (music_right),
        .mixed_left      (mixed_left),
        .mixed_right     (mixed_right)
    );
endmodule
