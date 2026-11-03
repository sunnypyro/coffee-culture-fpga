// Three low-resource transitions for the complete, already-composited video.
// Frame data stays in the existing SDRAM double buffer; this module only masks RGB.
module video_transition_mask (
    input wire picker_plain,picker_entry_quiesce,
    input  wire        video_clk,
    input  wire        rst,
    input  wire        hs_in,
    input  wire        vs_in,
    input  wire        de_in,
    input  wire [23:0] rgb_in,
    input  wire        display_valid,
    input  wire        pause_state,
    input  wire        display_commit_req_toggle,
    output reg         display_commit_ack_toggle,
    output wire        step_ui_idle,
    input  wire        display_commit_toggle,
    output wire        hs_out,
    output wire        vs_out,
    output wire        de_out,
    output wire [23:0] rgb_out
);
    localparam [2:0] ST_IDLE        = 3'd0;
    localparam [2:0] ST_WAIT_COMMIT = 3'd1;
    localparam [2:0] ST_BLACK       = 3'd2;
    localparam [2:0] ST_REVEAL      = 3'd3;
    localparam [2:0] ST_FADE_OUT    = 3'd4;
    localparam [2:0] ST_FADE_IN     = 3'd5;

    localparam [1:0] FX_CIRCLE = 2'd0;
    localparam [1:0] FX_MOSAIC = 2'd1;
    localparam [1:0] FX_FADE   = 2'd2;

    reg [9:0] pix_x;
    reg [9:0] pix_y;
    reg [9:0] x_d;
    reg [9:0] y_d;
    reg       hs_d;
    reg       vs_d_out;
    reg       de_d;
    reg [23:0] rgb_d;
    reg       vs_d_state;

    reg req_sync0;
    reg req_sync1;
    reg req_seen;
    reg commit_sync0;
    reg commit_sync1;
    reg commit_seen;
    reg display_seen;

    reg [2:0] state;
    reg [1:0] black_count;
    reg [4:0] reveal_step;
    reg [1:0] effect_active;
    reg [1:0] next_effect;
    reg       pending_request;
    reg [4:0] fade_gain;

    wire frame_start = vs_in && !vs_d_state;
    reg[1:0]entry_sync;reg entry_plain;
    always @(posedge video_clk or posedge rst)begin
     if(rst)begin entry_sync<=0;entry_plain<=0;end
     else begin entry_sync<={entry_sync[0],picker_entry_quiesce};if(frame_start)entry_plain<=entry_sync[1];end
    end
    wire request_event = display_seen && (req_sync1 != req_seen);
    assign step_ui_idle=display_seen && display_valid && state==ST_IDLE &&
                        !pending_request && !request_event && !entry_sync[1];

    // Keep the transition output and HS/VS/DE in one identical register stage.
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            pix_x    <= 10'd0;
            pix_y    <= 10'd0;
            x_d      <= 10'd0;
            y_d      <= 10'd0;
            hs_d     <= 1'b0;
            vs_d_out <= 1'b0;
            de_d     <= 1'b0;
            rgb_d    <= 24'd0;
            vs_d_state <= 1'b0;
        end else begin
            x_d        <= pix_x;
            y_d        <= pix_y;
            hs_d       <= hs_in;
            vs_d_out   <= vs_in;
            de_d       <= de_in;
            rgb_d      <= rgb_in;
            vs_d_state <= vs_in;

            if (de_in) begin
                if (pix_x == 10'd639) begin
                    pix_x <= 10'd0;
                    if (pix_y == 10'd479)
                        pix_y <= 10'd0;
                    else
                        pix_y <= pix_y + 10'd1;
                end else begin
                    pix_x <= pix_x + 10'd1;
                end
            end
        end
    end

    // Only single-bit toggle controls cross between SD and video clocks.
    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            req_sync0    <= 1'b0;
            req_sync1    <= 1'b0;
            commit_sync0 <= 1'b0;
            commit_sync1 <= 1'b0;
        end else begin
            req_sync0    <= display_commit_req_toggle;
            req_sync1    <= req_sync0;
            commit_sync0 <= display_commit_toggle;
            commit_sync1 <= commit_sync0;
        end
    end

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            state                       <= ST_IDLE;
            black_count                 <= 2'd0;
            reveal_step                 <= 5'd0;
            effect_active               <= FX_CIRCLE;
            next_effect                 <= FX_CIRCLE;
            pending_request             <= 1'b0;
            fade_gain                   <= 5'd16;
            display_commit_ack_toggle  <= 1'b0;
            req_seen                    <= 1'b0;
            commit_seen                 <= 1'b0;
            display_seen                <= 1'b0;
        end else if (!display_valid) begin
            state                       <= ST_IDLE;
            black_count                 <= 2'd0;
            reveal_step                 <= 5'd0;
            effect_active               <= FX_CIRCLE;
            next_effect                 <= FX_CIRCLE;
            pending_request             <= 1'b0;
            fade_gain                   <= 5'd16;
            display_commit_ack_toggle  <= 1'b0;
            req_seen                    <= req_sync1;
            commit_seen                 <= commit_sync1;
            display_seen                <= 1'b0;
        end else if (!display_seen) begin
            // The first valid image establishes protocol baselines without an effect.
            state                       <= ST_IDLE;
            black_count                 <= 2'd0;
            reveal_step                 <= 5'd0;
            effect_active               <= FX_CIRCLE;
            next_effect                 <= FX_CIRCLE;
            pending_request             <= 1'b0;
            fade_gain                   <= 5'd16;
            req_seen                    <= req_sync1;
            commit_seen                 <= commit_sync1;
            display_seen                <= 1'b1;
        end else begin
            if (request_event) begin
                req_seen        <= req_sync1;
                pending_request <= 1'b1;
            end

            // A commit is accepted only for a transition that reached its safe point.
            if (commit_sync1 != commit_seen) begin
                commit_seen <= commit_sync1;
                if (state == ST_WAIT_COMMIT) begin
                    if(entry_sync[1])state<=ST_IDLE;
                    else if (effect_active == FX_FADE) begin
                        state     <= ST_FADE_IN;
                        fade_gain <= 5'd0;
                    end else begin
                        state       <= ST_BLACK;
                        black_count <= 2'd0;
                        reveal_step <= 5'd0;
                    end
                end
            end

            if(entry_sync[1])begin
                if(frame_start)begin
                    if((pending_request&&!request_event)||state==ST_FADE_OUT)begin
                        pending_request<=0;state<=ST_WAIT_COMMIT;
                        display_commit_ack_toggle<=~display_commit_ack_toggle;
                    end else if(state!=ST_WAIT_COMMIT)state<=ST_IDLE;
                end
            end else case (state)
                ST_IDLE: begin
                    if (frame_start && pending_request && !request_event && !pause_state) begin
                        pending_request <= 1'b0;
                        effect_active   <= next_effect;
                        if (next_effect == FX_FADE)
                            next_effect <= FX_CIRCLE;
                        else
                            next_effect <= next_effect + 2'd1;

                        if (next_effect == FX_FADE) begin
                            state     <= ST_FADE_OUT;
                            fade_gain <= 5'd16;
                        end else begin
                            // Black is asserted before the acknowledgement crosses to SD.
                            state                       <= ST_WAIT_COMMIT;
                            black_count                 <= 2'd0;
                            reveal_step                 <= 5'd0;
                            display_commit_ack_toggle  <= ~display_commit_ack_toggle;
                        end
                    end
                end

                ST_WAIT_COMMIT: begin
                    // Keep RGB black until SD commits the already-written alternate buffer.
                end

                ST_BLACK: begin
                    if (frame_start && !pause_state) begin
                        if (black_count == 2'd1) begin
                            state       <= ST_REVEAL;
                            reveal_step <= 5'd0;
                        end else begin
                            black_count <= black_count + 2'd1;
                        end
                    end
                end

                ST_REVEAL: begin
                    if (frame_start && !pause_state) begin
                        if (reveal_step >= 5'd16)
                            state <= ST_IDLE;
                        else
                            reveal_step <= reveal_step + 5'd1;
                    end
                end

                ST_FADE_OUT: begin
                    if (frame_start && !pause_state) begin
                        if (fade_gain <= 5'd1) begin
                            fade_gain                  <= 5'd0;
                            state                      <= ST_WAIT_COMMIT;
                            display_commit_ack_toggle <= ~display_commit_ack_toggle;
                        end else begin
                            fade_gain <= fade_gain - 5'd1;
                        end
                    end
                end

                ST_FADE_IN: begin
                    if (frame_start && !pause_state) begin
                        if (fade_gain >= 5'd15) begin
                            fade_gain <= 5'd16;
                            state     <= ST_IDLE;
                        end else begin
                            fade_gain <= fade_gain + 5'd1;
                        end
                    end
                end

                default: begin
                    state           <= ST_IDLE;
                    black_count     <= 2'd0;
                    reveal_step     <= 5'd0;
                    pending_request <= 1'b0;
                    fade_gain       <= 5'd16;
                end
            endcase
        end
    end

    wire [9:0] dx = (x_d >= 10'd320) ? (x_d - 10'd320) : (10'd320 - x_d);
    wire [9:0] dy = (y_d >= 10'd240) ? (y_d - 10'd240) : (10'd240 - y_d);
    wire [9:0] step_u10 = {5'd0, reveal_step};
    wire [9:0] circle_radius = (step_u10 << 4) + (step_u10 << 3) + (step_u10 << 2);
    wire [19:0] dx_sq = dx * dx;
    wire [19:0] dy_sq = dy * dy;
    wire [20:0] circle_dist_sq = {1'b0, dx_sq} + {1'b0, dy_sq};
    wire [19:0] circle_radius_sq = circle_radius * circle_radius;

    wire [3:0] tile_x_mod = x_d[7:4];
    wire [3:0] tile_y_mod = y_d[7:4];
    wire [3:0] five_x = tile_x_mod + {tile_x_mod[1:0], 2'b00};
    wire [3:0] seven_y = tile_y_mod + {tile_y_mod[2:0], 1'b0} +
                         {tile_y_mod[1:0], 2'b00};
    wire [3:0] mosaic_rank = five_x + seven_y;

    reg reveal_visible;
    always @* begin
        if (reveal_step >= 5'd16) begin
            reveal_visible = 1'b1;
        end else begin
            case (effect_active)
                FX_CIRCLE: reveal_visible = (circle_dist_sq <= {1'b0, circle_radius_sq});
                FX_MOSAIC: reveal_visible = (mosaic_rank <= reveal_step[3:0]);
                default:   reveal_visible = 1'b1;
            endcase
        end
    end

    wire [11:0] red_product   = {4'b0, rgb_d[23:16]} * {7'b0, fade_gain};
    wire [11:0] green_product = {4'b0, rgb_d[15:8]}  * {7'b0, fade_gain};
    wire [11:0] blue_product  = {4'b0, rgb_d[7:0]}   * {7'b0, fade_gain};
    wire [23:0] rgb_faded = {red_product[11:4], green_product[11:4], blue_product[11:4]};

    reg [23:0] rgb_transition;
    always @* begin
        if (!display_valid)
            rgb_transition = 24'd0;
        else if(picker_plain||entry_plain)
            rgb_transition=rgb_d;
        else if (state == ST_WAIT_COMMIT)
            rgb_transition = pause_state ? rgb_d : 24'd0;
        else if (state == ST_BLACK)
            rgb_transition = 24'd0;
        else if (state == ST_REVEAL && !reveal_visible)
            rgb_transition = 24'd0;
        else if (state == ST_FADE_OUT || state == ST_FADE_IN)
            rgb_transition = rgb_faded;
        else
            rgb_transition = rgb_d;
    end

    assign hs_out  = hs_d;
    assign vs_out  = vs_d_out;
    assign de_out  = de_d;
    assign rgb_out = rgb_transition;
endmodule
