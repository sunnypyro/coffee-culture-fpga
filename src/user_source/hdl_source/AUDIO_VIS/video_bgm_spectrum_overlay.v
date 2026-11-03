module video_bgm_spectrum_overlay #(
    parameter integer SW2_STABLE_CYCLES = 125000
) (
    input wire suppress_draw,
    input  wire        video_clk,
    input  wire        rst,
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire        de_in,
    input  wire [23:0] rgb_in,
    input  wire        display_ready,
    input  wire        sw2_enable_async,
    input  wire        pause_state,
    output reg  [3:0]  pause_attenuation,
    input  wire        spectrum_frame_ready,
    input  wire        spectrum_height_valid,
    input  wire [5:0]  spectrum_height_index,
    input  wire [3:0]  spectrum_height_value,
    input  wire        spectrum_clear,
    output reg         hs_out,
    output reg         vs_out,
    output reg         de_out,
    output reg  [23:0] rgb_out
);

    localparam [9:0] PANEL_X0       = 10'd64;
    localparam [9:0] PANEL_X1       = 10'd575;
    localparam [9:0] PANEL_Y0       = 10'd370;
    localparam [9:0] PANEL_BASE_Y   = 10'd432;
    localparam [9:0] PANEL_MAX_Y    = 10'd440;
    localparam [9:0] FRAME_LAST_X   = 10'd639;
    localparam [9:0] FRAME_LAST_Y   = 10'd479;

    reg [9:0] pix_x;
    reg [9:0] pix_y;
    reg       vs_prev;
    wire frame_start = vs_in && !vs_prev;
    wire line_start = de_in && (pix_x == 10'd0);

    wire column_prepare =
        de_in && (pix_x >= 10'd60) && (pix_x <= 10'd564) &&
        (pix_x[2:0] == 3'd4);

    reg        sw2_meta;
    reg        sw2_sync;
    reg        sw2_stable;
    reg        sw2_visible;
    reg [16:0] sw2_count;

    reg        spectrum_update_pending;
    reg        active_height_bank;
    reg        height_bank0_valid;
    reg        height_bank1_valid;
    reg        height_read_pending;

    reg [5:0]  bar_height_current;
    reg [23:0] bar_color_current;
    reg [5:0]  column_index;
    reg [5:0]  row_up_distance;
    reg [3:0]  row_reflection_distance;
    reg        row_bar_region;
    reg        row_panel_region;
    reg        row_baseline;
    reg [23:0] rgb_next;
    wire [2:0] pause_fade_count = pause_attenuation[3:1];
    wire [6:0] height_read_address = {active_height_bank, column_index};
    wire [6:0] height_write_address = {~active_height_bank, spectrum_height_index};
    wire [3:0] height_bram_read_data;
    wire       active_height_bank_valid = active_height_bank
                                        ? height_bank1_valid : height_bank0_valid;
    wire [3:0] height_read_data = active_height_bank_valid
                                ? height_bram_read_data : 4'd0;
    wire [2:0] attenuated_height_upper =
        (height_read_data[3:1] > pause_fade_count)
        ? height_read_data[3:1] - pause_fade_count : 3'd0;
    wire [3:0] display_height_data =
        (attenuated_height_upper != 3'd0)
        ? {attenuated_height_upper, height_read_data[0]} : 4'd1;

    function [23:0] gradient_color;
        input [3:0] index;
        begin
            case (index)
                4'd0:  gradient_color = 24'hFF433A;
                4'd1:  gradient_color = 24'hFF7134;
                4'd2:  gradient_color = 24'hFF9A35;
                4'd3:  gradient_color = 24'hFFCC44;
                4'd4:  gradient_color = 24'hDCE748;
                4'd5:  gradient_color = 24'h8FE246;
                4'd6:  gradient_color = 24'h26DCCA;
                4'd7:  gradient_color = 24'h29B4E6;
                4'd8:  gradient_color = 24'h3B9CFF;
                4'd9:  gradient_color = 24'h5574FF;
                4'd10: gradient_color = 24'h635BFF;
                4'd11: gradient_color = 24'h9057F4;
                4'd12: gradient_color = 24'hBE50E9;
                4'd13: gradient_color = 24'hDC54E5;
                4'd14: gradient_color = 24'hE241CE;
                default: gradient_color = 24'hE735AA;
            endcase
        end
    endfunction

    video_bgm_spectrum_height_bram u_height_bram (
        .clk(video_clk),
        .write_enable(spectrum_height_valid && !spectrum_clear),
        .write_address(height_write_address),
        .write_data(spectrum_height_value),
        .read_enable(column_prepare),
        .read_address(height_read_address),
        .read_data(height_bram_read_data)
    );

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            sw2_meta    <= 1'b0;
            sw2_sync    <= 1'b0;
            sw2_stable  <= 1'b0;
            sw2_visible <= 1'b0;
            sw2_count   <= 17'd0;
        end else begin
            sw2_meta <= sw2_enable_async;
            sw2_sync <= sw2_meta;

            if (sw2_sync == sw2_stable) begin
                sw2_count <= 17'd0;
            end else if (sw2_count == SW2_STABLE_CYCLES - 1) begin
                sw2_stable <= sw2_sync;
                sw2_count  <= 17'd0;
            end else begin
                sw2_count <= sw2_count + 17'd1;
            end

            if (frame_start)
                sw2_visible <= sw2_stable;
        end
    end

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            pix_x                    <= 10'd0;
            pix_y                    <= 10'd0;
            vs_prev                  <= 1'b0;
            spectrum_update_pending  <= 1'b0;
            active_height_bank      <= 1'b0;
            height_bank0_valid      <= 1'b0;
            height_bank1_valid      <= 1'b0;
            height_read_pending     <= 1'b0;
            pause_attenuation      <= 4'd0;
            hs_out                   <= 1'b0;
            vs_out                   <= 1'b0;
            de_out                   <= 1'b0;
            rgb_out                  <= 24'd0;
            bar_height_current       <= 6'd0;
            bar_color_current        <= 24'hFF433A;
            column_index             <= 6'd0;
            row_up_distance          <= 6'd0;
            row_reflection_distance  <= 4'd0;
            row_bar_region           <= 1'b0;
            row_panel_region         <= 1'b0;
            row_baseline             <= 1'b0;
        end else begin
            vs_prev <= vs_in;

            if (spectrum_clear) begin
                spectrum_update_pending <= 1'b0;
                active_height_bank <= 1'b0;
                height_bank0_valid <= 1'b0;
                height_bank1_valid <= 1'b0;
                pause_attenuation <= 4'd0;
            end else if (pause_state) begin
                // Keep the active frequency table and lower its displayed
                // heights by two levels on each video-frame boundary.
                spectrum_update_pending <= 1'b0;
                if (frame_start && (pause_attenuation < 4'd14))
                    pause_attenuation <= pause_attenuation + 4'd2;
            end else begin
                if (spectrum_frame_ready) begin
                    spectrum_update_pending <= 1'b1;
                    if (active_height_bank)
                        height_bank0_valid <= 1'b1;
                    else
                        height_bank1_valid <= 1'b1;
                end
                if (frame_start && (spectrum_update_pending || spectrum_frame_ready)) begin
                    active_height_bank <= !active_height_bank;
                    spectrum_update_pending <= 1'b0;
                    pause_attenuation <= 4'd0;
                end
            end

            if (spectrum_clear) begin
                height_read_pending <= 1'b0;
                bar_height_current <= 6'd4;
            end else begin
                height_read_pending <= column_prepare;
                if (height_read_pending)
                    bar_height_current <= {display_height_data, 2'b00};
            end

            if (line_start) begin
                column_index <= 6'd0;
                row_panel_region <=
                    (pix_y >= PANEL_Y0) && (pix_y <= PANEL_MAX_Y);
                row_bar_region <=
                    (pix_y >= PANEL_Y0) && (pix_y < PANEL_BASE_Y);
                row_up_distance <=
                    ((pix_y >= PANEL_Y0) && (pix_y < PANEL_BASE_Y))
                    ? (PANEL_BASE_Y - pix_y) : 6'd0;
                row_reflection_distance <=
                    ((pix_y > PANEL_BASE_Y) && (pix_y <= PANEL_MAX_Y))
                    ? (pix_y - PANEL_BASE_Y) : 4'd0;
                row_baseline <= (pix_y == PANEL_BASE_Y);
            end

            if (column_prepare) begin
                bar_color_current <= gradient_color(column_index[5:2]);
                column_index <= column_index + 6'd1;
            end

            if (de_in) begin
                if (pix_x == FRAME_LAST_X) begin
                    pix_x <= 10'd0;
                    if (pix_y == FRAME_LAST_Y)
                        pix_y <= 10'd0;
                    else
                        pix_y <= pix_y + 10'd1;
                end else begin
                    pix_x <= pix_x + 10'd1;
                end
            end

            hs_out <= hs_in;
            vs_out <= vs_in;
            de_out <= de_in;
            rgb_out <= suppress_draw?rgb_in:rgb_next;
        end
    end

    wire panel_x = (pix_x >= PANEL_X0) && (pix_x <= PANEL_X1);
    wire bar_slot = (pix_x[2:0] < 3'd5);
    wire overlay_visible = sw2_visible && display_ready;
    wire spectrum_bars_visible = overlay_visible;
    wire [5:0] rendered_bar_height = spectrum_clear ? 6'd4 : bar_height_current;
    wire bar_pixel =
        spectrum_bars_visible && de_in && panel_x && bar_slot &&
        row_bar_region && (row_up_distance != 6'd0) &&
        (rendered_bar_height >= row_up_distance);
    wire bar_top_pixel = bar_pixel && (rendered_bar_height == row_up_distance);
    wire reflection_pixel =
        spectrum_bars_visible && de_in && panel_x && bar_slot && row_panel_region &&
        (row_reflection_distance != 4'd0) &&
        (row_reflection_distance <= rendered_bar_height[5:2]);
    wire baseline_pixel = overlay_visible && de_in && panel_x && row_panel_region && row_baseline;
    wire [23:0] top_color = bar_color_current | 24'h202020;
    wire [23:0] reflection_color = {
        2'b00, bar_color_current[23:18],
        2'b00, bar_color_current[15:10],
        2'b00, bar_color_current[7:2]
    };

    always @* begin
        rgb_next = rgb_in;
        if (overlay_visible && de_in) begin
            if (bar_top_pixel)
                rgb_next = top_color;
            else if (bar_pixel)
                rgb_next = bar_color_current;
            else if (reflection_pixel)
                rgb_next = reflection_color;
            else if (baseline_pixel)
                rgb_next = 24'h203B4A;
        end
    end
endmodule
