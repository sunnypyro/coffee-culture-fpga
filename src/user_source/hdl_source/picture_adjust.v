// RGB picture adjustment stage retained in the existing display pipeline.
// Levels are signed -8..+8.  Zero is transparent.
module picture_adjust (
    input  wire [23:0]       rgb_in,
    input  wire signed [4:0] brightness_level,
    input  wire signed [4:0] contrast_level,
    output wire [23:0]       rgb_out
);
    function [7:0] clamp8;
        input signed [12:0] value;
        begin
            if (value < 13'sd0)
                clamp8 = 8'd0;
            else if (value > 13'sd255)
                clamp8 = 8'd255;
            else
                clamp8 = value[7:0];
        end
    endfunction

    function signed [12:0] contrast_delta;
        input signed [12:0] d;
        input signed [4:0]  level;
        reg        [3:0] magnitude;
        reg signed [12:0] term16;
        reg signed [12:0] term8;
        reg signed [12:0] term4;
        reg signed [12:0] term2;
        reg                level_valid;
        begin
            level_valid = level[4] ? level[3] :
                          (!level[3] || (level[2:0] == 3'b000));
            magnitude = level[4] ? (4'd0 - level[3:0]) : level[3:0];

            term16 = magnitude[0] ? (level[4] ? -(d >>> 4) : (d >>> 4)) : 13'sd0;
            term8  = magnitude[1] ? (level[4] ? -(d >>> 3) : (d >>> 3)) : 13'sd0;
            term4  = magnitude[2] ? (level[4] ? -(d >>> 2) : (d >>> 2)) : 13'sd0;
            term2  = magnitude[3] ? (level[4] ? -(d >>> 1) : (d >>> 1)) : 13'sd0;

            if (level_valid)
                contrast_delta = d + term16 + term8 + term4 + term2;
            else
                contrast_delta = d;
        end
    endfunction

    function [7:0] adjust_channel;
        input [7:0]       pixel;
        input signed [4:0] brightness;
        input signed [4:0] contrast;
        reg signed [12:0] d;
        reg signed [12:0] adjusted;
        begin
            d = $signed({1'b0, pixel}) - 13'sd128;
            adjusted = 13'sd128 + contrast_delta(d, contrast) + (brightness <<< 3);
            adjust_channel = clamp8(adjusted);
        end
    endfunction

    assign rgb_out = {
        adjust_channel(rgb_in[23:16], brightness_level, contrast_level),
        adjust_channel(rgb_in[15:8],  brightness_level, contrast_level),
        adjust_channel(rgb_in[7:0],   brightness_level, contrast_level)
    };
endmodule
