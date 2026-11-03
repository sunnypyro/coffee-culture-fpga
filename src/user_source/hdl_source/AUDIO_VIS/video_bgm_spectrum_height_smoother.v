module video_bgm_spectrum_height_smoother (
    input  wire       clk,
    input  wire       rst,
    input  wire       spectrum_clear,
    input  wire       pause_state,
    input  wire       height_valid,
    input  wire [5:0] height_index,
    input  wire [3:0] height_value,
    input  wire       frame_ready,
    output reg        smoothed_height_valid,
    output reg  [5:0] smoothed_height_index,
    output reg  [3:0] smoothed_height_value,
    output reg        smoothed_frame_ready
);

    localparam [3:0] MAX_RISE_PER_FRAME = 4'd3;
    localparam [3:0] MAX_FALL_PER_FRAME = 4'd1;

    reg        pending_valid;
    reg        pending_frame_ready;
    reg [5:0]  pending_index;
    reg [3:0]  pending_target;
    reg        state_clear_busy;
    reg [5:0]  state_clear_index;
    reg        pause_prev;

    wire [3:0] state_read_data;
    wire [3:0] previous_height = state_read_data;
    wire [3:0] rise_delta = pending_target - previous_height;
    wire [3:0] fall_delta = previous_height - pending_target;
    reg [3:0] next_height;

    wire state_read_enable = height_valid && !pause_state && !spectrum_clear && !state_clear_busy;
    wire state_write_enable = state_clear_busy ||
                              (pending_valid && !pause_state && !spectrum_clear);
    wire [5:0] state_write_address = state_clear_busy ? state_clear_index : pending_index;
    wire [3:0] state_write_data = state_clear_busy ? 4'd0 : next_height;

    video_bgm_spectrum_smoother_state_bram u_smoother_state_bram (
        .clk(clk),
        .read_enable(state_read_enable),
        .read_address(height_index),
        .read_data(state_read_data),
        .write_enable(state_write_enable),
        .write_address(state_write_address),
        .write_data(state_write_data)
    );

    always @* begin
        next_height = previous_height;
        if (pending_target > previous_height) begin
            if (rise_delta > MAX_RISE_PER_FRAME)
                next_height = previous_height + MAX_RISE_PER_FRAME;
            else
                next_height = pending_target;
        end else if (pending_target < previous_height) begin
            if (fall_delta > MAX_FALL_PER_FRAME)
                next_height = previous_height - MAX_FALL_PER_FRAME;
            else
                next_height = pending_target;
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            pending_valid          <= 1'b0;
            pending_frame_ready    <= 1'b0;
            pending_index          <= 6'd0;
            pending_target         <= 4'd0;
            state_clear_busy       <= 1'b1;
            state_clear_index      <= 6'd0;
            pause_prev             <= 1'b0;
            smoothed_height_valid  <= 1'b0;
            smoothed_height_index  <= 6'd0;
            smoothed_height_value  <= 4'd0;
            smoothed_frame_ready   <= 1'b0;
        end else begin
            pause_prev <= pause_state;
            smoothed_height_valid <= 1'b0;
            smoothed_frame_ready <= 1'b0;

            if ((spectrum_clear || (pause_state && !pause_prev)) &&
                !state_clear_busy) begin
                state_clear_busy <= 1'b1;
                state_clear_index <= 6'd0;
            end

            if (state_clear_busy) begin
                if (state_clear_index == 6'd63)
                    state_clear_busy <= 1'b0;
                else
                    state_clear_index <= state_clear_index + 6'd1;
            end

            if (spectrum_clear || pause_state) begin
                pending_valid         <= 1'b0;
                pending_frame_ready   <= 1'b0;
                smoothed_height_index <= 6'd0;
                smoothed_height_value <= 4'd0;
            end else begin
                pending_valid <= height_valid && !state_clear_busy;
                pending_frame_ready <= frame_ready && !state_clear_busy;

                if (height_valid && !state_clear_busy) begin
                    pending_index <= height_index;
                    pending_target <= height_value;
                end

                if (pending_valid && !state_clear_busy) begin
                    smoothed_height_valid <= 1'b1;
                    smoothed_height_index <= pending_index;
                    smoothed_height_value <= next_height;
                    smoothed_frame_ready <= pending_frame_ready;
                end
            end
        end
    end

endmodule
