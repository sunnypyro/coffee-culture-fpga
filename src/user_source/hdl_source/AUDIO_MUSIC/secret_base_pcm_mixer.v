// Mixes streamed Secret Base PCM with narration. music_left/right are full-level
// analyzer taps; only the playback branch receives the fixed 5/8 attenuation.
module secret_base_pcm_mixer (
    input  wire                    sample_valid,
    input  wire                    music_enable,
    input  wire                    pause_state,
    input  wire                    bgm_sample_valid,
    input  wire signed [15:0]      bgm_sample,
    input  wire signed [23:0]      voice_left,
    input  wire signed [23:0]      voice_right,
    output wire signed [23:0]      music_left,
    output wire signed [23:0]      music_right,
    output reg  signed [23:0]      mixed_left,
    output reg  signed [23:0]      mixed_right
);
    wire signed [23:0] bgm_pcm_aligned = $signed({bgm_sample, 8'b0});
    wire signed [23:0] bgm_pcm_playback = (bgm_pcm_aligned >>> 1) +
                                          (bgm_pcm_aligned >>> 3);
    wire bgm_sample_enable = sample_valid && music_enable && !pause_state &&
                             bgm_sample_valid;

    assign music_left = bgm_sample_enable ? bgm_pcm_aligned : 24'sd0;
    assign music_right = music_left;
    wire signed [23:0] playback_left =
        bgm_sample_enable ? bgm_pcm_playback : 24'sd0;
    wire signed [23:0] playback_right = playback_left;

    reg signed [24:0] left_sum;
    reg signed [24:0] right_sum;
    always @* begin
        left_sum  = $signed({voice_left[23], voice_left}) +
                    $signed({playback_left[23], playback_left});
        right_sum = $signed({voice_right[23], voice_right}) +
                    $signed({playback_right[23], playback_right});

        if (!voice_left[23] && !playback_left[23] && left_sum[23])
            mixed_left = 24'sh7fffff;
        else if (voice_left[23] && playback_left[23] && !left_sum[23])
            mixed_left = 24'sh800000;
        else
            mixed_left = left_sum[23:0];

        if (!voice_right[23] && !playback_right[23] && right_sum[23])
            mixed_right = 24'sh7fffff;
        else if (voice_right[23] && playback_right[23] && !right_sum[23])
            mixed_right = 24'sh800000;
        else
            mixed_right = right_sum[23:0];
    end
endmodule
