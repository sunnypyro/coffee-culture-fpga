// Playback pause and direct brightness/contrast adjustment.
// Physical controls:
//   KEY1 = A2 reset
//   KEY3 = B1 pause/resume while idle; confirm while adjusting
//   SW3 = C6 contrast
//   SW4 = C5 brightness
// SW1/C8 is unused; SW2/C7 controls the audio visualization.
module display_button_debounce #(
    parameter integer DEBOUNCE_CYCLES = 1_000_000
) (
    input  wire clk,
    input  wire rst,
    input  wire button_in,
    output reg  press_pulse
);
    reg sync0, sync1, stable;
    reg [31:0] count;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sync0       <= 1'b1;
            sync1       <= 1'b1;
            stable      <= 1'b1;
            count       <= 32'd0;
            press_pulse <= 1'b0;
        end else begin
            sync0       <= button_in;
            sync1       <= sync0;
            press_pulse <= 1'b0;

            if (sync1 == stable) begin
                count <= 32'd0;
            end else if (count >= DEBOUNCE_CYCLES - 1) begin
                if (stable && !sync1)
                    press_pulse <= 1'b1;
                stable <= sync1;
                count  <= 32'd0;
            end else begin
                count <= count + 32'd1;
            end
        end
    end
endmodule

module display_switch_debounce #(
    parameter integer DEBOUNCE_CYCLES = 1_000_000
) (
    input  wire clk,
    input  wire rst,
    input  wire switch_in,
    output reg  stable_level,
    output reg  change_pulse
);
    reg sync0, sync1;
    reg [31:0] count;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            sync0        <= 1'b0;
            sync1        <= 1'b0;
            stable_level <= 1'b0;
            change_pulse <= 1'b0;
            count        <= 32'd0;
        end else begin
            sync0        <= switch_in;
            sync1        <= sync0;
            change_pulse <= 1'b0;

            if (sync1 == stable_level) begin
                count <= 32'd0;
            end else if (count >= DEBOUNCE_CYCLES - 1) begin
                stable_level <= sync1;
                change_pulse <= 1'b1;
                count        <= 32'd0;
            end else begin
                count <= count + 32'd1;
            end
        end
    end
endmodule

module display_control #(
    parameter integer DEBOUNCE_CYCLES = 1_000_000,
    parameter integer RATE_CYCLES     = 25_000_000
) (
    input  wire clk,
    input  wire rst,
    input wire control_hold,select_resume,
    input  wire display_ready,
    input  wire key_pause,          // 板上 KEY3：暂停/恢复；调节中=确认
    input  wire sw3_contrast,
    input  wire sw4_brightness,

    output reg        pause_state,
    output reg        adjust_active,
    output reg [1:0]  active_param,
    output reg signed [4:0] brightness_level,
    output reg signed [4:0] contrast_level
);
    localparam [1:0] PARAM_NONE       = 2'd0;
    localparam [1:0] PARAM_BRIGHTNESS = 2'd1;
    localparam [1:0] PARAM_CONTRAST   = 2'd2;

    wire key_press;
    wire sw3_changed;
    wire sw4_changed;
    wire sw3_level;
    wire sw4_level;

    display_button_debounce #(
        .DEBOUNCE_CYCLES (DEBOUNCE_CYCLES)
    ) u_key3_debounce (
        .clk         (clk),
        .rst         (rst),
        .button_in   (key_pause),
        .press_pulse (key_press)
    );

    display_switch_debounce #(
        .DEBOUNCE_CYCLES (DEBOUNCE_CYCLES)
    ) u_sw3_debounce (
        .clk          (clk),
        .rst          (rst),
        .switch_in    (sw3_contrast),
        .stable_level (sw3_level),
        .change_pulse (sw3_changed)
    );

    display_switch_debounce #(
        .DEBOUNCE_CYCLES (DEBOUNCE_CYCLES)
    ) u_sw4_debounce (
        .clk          (clk),
        .rst          (rst),
        .switch_in    (sw4_brightness),
        .stable_level (sw4_level),
        .change_pulse (sw4_changed)
    );

    reg ready0, ready1;
    reg [31:0] rate_count;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            ready0           <= 1'b0;
            ready1           <= 1'b0;
            pause_state      <= 1'b0;
            adjust_active    <= 1'b0;
            active_param     <= PARAM_NONE;
            brightness_level <= 5'sd0;
            contrast_level   <= 5'sd0;
            rate_count       <= 32'd0;
        end else begin
            ready0 <= display_ready;
            ready1 <= ready0;

            if (!ready1) begin
                // 首图还没出来：没有画面可调，也不允许暂停
                adjust_active <= 1'b0;
                active_param  <= PARAM_NONE;
                rate_count    <= 32'd0;
            end else if(select_resume)begin
                pause_state<=0;adjust_active<=0;active_param<=PARAM_NONE;rate_count<=0;
            end else if(control_hold)begin
                adjust_active<=0;active_param<=PARAM_NONE;rate_count<=0;
            end else if (adjust_active) begin
                // 调节中按 KEY3 确认并锁定当前参数
                if (key_press) begin
                    adjust_active <= 1'b0;
                    active_param  <= PARAM_NONE;
                    rate_count    <= 32'd0;
                end
                // 活动参数开关反向拨动：只重新计时，不立刻多跳一级
                else if ((active_param == PARAM_BRIGHTNESS && sw4_changed) ||
                         (active_param == PARAM_CONTRAST   && sw3_changed)) begin
                    rate_count <= 32'd0;
                end
                // 每 RATE_CYCLES 才改一级；到 ±8 保持边界不回绕
                else if (rate_count >= RATE_CYCLES - 1) begin
                    rate_count <= 32'd0;
                    if (active_param == PARAM_BRIGHTNESS) begin
                        if (sw4_level && (brightness_level < 5'sd8))
                            brightness_level <= brightness_level + 5'sd1;
                        else if (!sw4_level && (brightness_level > -5'sd8))
                            brightness_level <= brightness_level - 5'sd1;
                    end else if (active_param == PARAM_CONTRAST) begin
                        if (sw3_level && (contrast_level < 5'sd8))
                            contrast_level <= contrast_level + 5'sd1;
                        else if (!sw3_level && (contrast_level > -5'sd8))
                            contrast_level <= contrast_level - 5'sd1;
                    end
                end else begin
                    rate_count <= rate_count + 32'd1;
                end
            end else begin
                // 空闲时 KEY3 暂停/恢复；拨动 SW3/SW4 直接开始对应调节
                if (key_press) begin
                    pause_state <= ~pause_state;
                end else if (sw4_changed && !sw3_changed) begin
                    adjust_active <= 1'b1;
                    active_param  <= PARAM_BRIGHTNESS;
                    rate_count    <= 32'd0;
                end else if (sw3_changed && !sw4_changed) begin
                    adjust_active <= 1'b1;
                    active_param  <= PARAM_CONTRAST;
                    rate_count    <= 32'd0;
                end
                // 同拍双变化不猜参数；两个变化都消费，用户需重新拨单个开关
            end
        end
    end
endmodule