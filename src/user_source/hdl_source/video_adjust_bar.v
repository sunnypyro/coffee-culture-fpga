// Compact right-side adjustment indicator.
// The control session owns the numeric value; this module only renders it.
//
// 动画（2026-09-21，按用户要求）：
//   开始调节        : 条从右侧滑入（每帧 -2 px，640 -> 606，17 帧 ≈ 0.28 s）
//   调节中          : 停在 606..623
//   确认 / 离开调节界面: **先在原位停留 30 帧 ≈ 0.5 s**，再按滑入同样的速度
//                    反向滑出（每帧 +2 px，606 -> 640），完全出屏后隐藏
//   停留或滑出中途又重新开始调节：从当前位置滑回 606，停留计时清零
module video_adjust_bar (
    input wire suppress_draw,
    input  wire              video_clk,
    input  wire              rst,
    input  wire              hs_in,
    input  wire              vs_in,
    input  wire              de_in,
    input  wire [23:0]       rgb_in,
    input  wire              adjust_active,
    input  wire [1:0]        active_param,
    input  wire signed [4:0] brightness_level,
    input  wire signed [4:0] contrast_level,
    output wire              hs_out,
    output wire              vs_out,
    output wire              de_out,
    output wire [23:0]       rgb_out,
    output wire              bar_visible,
    output wire [1:0]        param_out
);
    localparam integer BAR_X0 = 606;
    localparam integer BAR_X1 = 623;
    localparam integer BAR_Y0 = 152;
    localparam integer BAR_Y1 = 328;
    localparam integer BAR_CY = 240;
    localparam integer HOLD_FRAMES = 30;    // 确认后停留 ≈ 0.5 s（60 Hz 视频帧）
    localparam integer STEP_PX     = 2;     // 每帧移动像素数（滑入/滑出同一个速度）

    reg [9:0] pix_x, pix_y;
    reg [9:0] x_d, y_d;
    reg hs_d, vs_d, de_d;
    reg [23:0] rgb_d;
    reg active_v0, active_v1;
    reg [1:0] param_v0, param_v1;
    reg signed [4:0] bright_v0, bright_v1;
    reg signed [4:0] contrast_v0, contrast_v1;
    reg [10:0] bar_x;
    reg vs_prev;
    reg [5:0] hold_cnt;         // 确认后的停留计时（帧）；会话进行中一直装满
    reg [1:0] param_show;       // 本次会话的活动参数：停留+滑出期间必须保持
                                // （确认时 display_control 会把 active_param 清 0，
                                //   不锁存的话颜色会从金黄变紫、指示块会跳回中心）

    wire frame_start = vs_in & ~vs_prev;

    function signed [9:0] marker_y;
        input signed [4:0] level;
        begin
            case (level)
                -5'sd8: marker_y = 10'sd320;
                -5'sd7: marker_y = 10'sd310;
                -5'sd6: marker_y = 10'sd300;
                -5'sd5: marker_y = 10'sd290;
                -5'sd4: marker_y = 10'sd280;
                -5'sd3: marker_y = 10'sd270;
                -5'sd2: marker_y = 10'sd260;
                -5'sd1: marker_y = 10'sd250;
                 5'sd1: marker_y = 10'sd230;
                 5'sd2: marker_y = 10'sd220;
                 5'sd3: marker_y = 10'sd210;
                 5'sd4: marker_y = 10'sd200;
                 5'sd5: marker_y = 10'sd190;
                 5'sd6: marker_y = 10'sd180;
                 5'sd7: marker_y = 10'sd170;
                 5'sd8: marker_y = 10'sd160;
                default: marker_y = 10'sd240;
            endcase
        end
    endfunction

    // 指示块位置：0 = 正中心（BAR_CY），±8 = 上下两端
    // （marker_y 返回的都是 160..320 的正数，这里按无符号比较，
    //   避免有符号/无符号混用带来的隐式转换问题）
    // 显示阶段用的活动参数：会话进行中用实时值（无延迟），
    // 停留 / 滑出期间用锁存值（颜色和指示块位置都要保持不变）
    wire [1:0] param_use = active_v1 ? param_v1 : param_show;
    wire [9:0] marker_center = (param_use == 2'd1) ? marker_y(bright_v1) : marker_y(contrast_v1);
    wire [23:0] bar_color = (param_use == 2'd1) ? 24'hFFD23F : 24'hC080FF;
    // 条只要还在屏上就要画（滑入 / 停留 / 滑出三个阶段都要看得见）。
    // 原来这里挂的是 active_v1 ⇒ 确认的那一瞬间条就消失了，"先停半秒再滑出"
    // 和"滑出动画"全都被吃掉（2026-09-21 修）。
    wire bar_on_screen = (bar_x < 11'd640);
    wire [10:0] bar_local_x = {1'b0, x_d} - bar_x;
    wire bar_area = bar_on_screen &&
                    (bar_local_x <= 11'd17) &&
                    (y_d >= BAR_Y0) && (y_d <= BAR_Y1) && de_d;
    wire bar_border = bar_area &&
                      ((bar_local_x == 11'd0) || (bar_local_x == 11'd17) ||
                       (y_d == BAR_Y0) || (y_d == BAR_Y1));
    wire bar_track = bar_area && (bar_local_x >= 11'd7) && (bar_local_x <= 11'd10);
    wire bar_zero = bar_area && (y_d >= BAR_CY - 1) && (y_d <= BAR_CY + 1);
    // 指示块 = 圆润的八角形（规格要求"圆润/平滑，不能是老式方块条"）：
    //   横向 12 px（dx 0..11），纵向 11 px（dy 0..5），四角各削两级倒角
    wire [10:0] mk_dx = bar_local_x - 11'd3;
    wire [10:0] mk_dy = (y_d >= marker_center) ? (y_d - marker_center)
                                              : (marker_center - y_d);
    wire bar_marker = bar_area &&
                      (mk_dx <= 11'd11) &&
                      ((mk_dy <= 11'd3) ||
                       ((mk_dy == 11'd4) && (mk_dx >= 11'd2) && (mk_dx <= 11'd9)) ||
                       ((mk_dy == 11'd5) && (mk_dx >= 11'd4) && (mk_dx <= 11'd7)));

    always @(posedge video_clk or posedge rst) begin
        if (rst) begin
            pix_x       <= 10'd0;
            pix_y       <= 10'd0;
            x_d         <= 10'd0;
            y_d         <= 10'd0;
            hs_d        <= 1'b0;
            vs_d        <= 1'b0;
            de_d        <= 1'b0;
            rgb_d       <= 24'd0;
            active_v0   <= 1'b0;
            active_v1   <= 1'b0;
            param_v0    <= 2'd0;
            param_v1    <= 2'd0;
            bright_v0   <= 5'sd0;
            bright_v1   <= 5'sd0;
            contrast_v0 <= 5'sd0;
            contrast_v1 <= 5'sd0;
            bar_x       <= 11'd640;
            vs_prev     <= 1'b0;
            hold_cnt    <= 6'd0;
            param_show  <= 2'd0;
        end else begin
            x_d       <= pix_x;
            y_d       <= pix_y;
            hs_d      <= hs_in;
            vs_d      <= vs_in;
            de_d      <= de_in;
            rgb_d     <= rgb_in;
            vs_prev   <= vs_in;
            active_v0 <= adjust_active;
            active_v1 <= active_v0;
            param_v0  <= active_param;
            param_v1  <= param_v0;
            bright_v0 <= brightness_level;
            bright_v1 <= bright_v0;
            contrast_v0 <= contrast_level;
            contrast_v1 <= contrast_v0;

            // 会话进行中：记住这次调节的是哪个参数（停留/滑出期间要用）
            if (active_v1 && (param_v1 != 2'd0))
                param_show <= param_v1;

            // 每帧只做一件事：滑入 / 停留倒数 / 反向滑出
            if (frame_start) begin
                if (active_v1) begin
                    // 会话进行中：滑入到位，并把停留计时重新装满
                    hold_cnt <= HOLD_FRAMES[5:0];
                    if (bar_x > BAR_X0)
                        bar_x <= bar_x - STEP_PX[10:0];
                end
                else if (hold_cnt != 6'd0) begin
                    // 确认/离开调节界面：先在原位停留，位置不动
                    hold_cnt <= hold_cnt - 6'd1;
                end
                else if (bar_x < 11'd640) begin
                    // 停留结束：按滑入同样的速度反向滑出
                    bar_x <= bar_x + STEP_PX[10:0];
                end
            end

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

    reg [23:0] rgb_bar;
    always @* begin
        rgb_bar = rgb_d;
        if (bar_area) begin
            if (bar_border)
                rgb_bar = 24'h101318;
            else if (bar_marker)
                rgb_bar = bar_color;
            else if (bar_zero)
                rgb_bar = 24'hFFFFFF;
            else if (bar_track)
                rgb_bar = 24'h3A4148;
            else
                rgb_bar = 24'h151A20;
        end
    end

    assign hs_out  = hs_d;
    assign vs_out  = vs_d;
    assign de_out  = de_d;
    assign rgb_out = suppress_draw?rgb_d:rgb_bar;
    assign bar_visible = bar_on_screen;
    assign param_out = param_use;
endmodule
