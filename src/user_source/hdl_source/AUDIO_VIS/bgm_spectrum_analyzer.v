module bgm_spectrum_analyzer (
    input  wire                    clk,
    input  wire                    rst,
    input  wire                    sample_valid,
    input  wire                    music_active,
    input  wire                    pause_state,
    input  wire signed [7:0]       bgm_sample,
    output reg  [5:0]              height_index,
    output reg  [3:0]              height_value,
    output reg                     height_valid,
    output reg                     frame_ready,
    output wire                    spectrum_clear
);

    localparam [3:0] ST_CAPTURE             = 4'd0;
    localparam [3:0] ST_BIN_START           = 4'd1;
    localparam [3:0] ST_PROCESS_SETUP       = 4'd2;
    localparam [3:0] ST_PROCESS             = 4'd3;
    localparam [3:0] ST_FINAL_COS_SETUP     = 4'd4;
    localparam [3:0] ST_FINAL_COS_CAPTURE   = 4'd5;
    localparam [3:0] ST_FINAL_SIN_CAPTURE   = 4'd6;
    localparam [3:0] ST_FINAL_MAGNITUDE     = 4'd7;

    localparam [10:0] LAST_SAMPLE = 11'd2047;
    localparam [5:0] LAST_BIN = 6'd63;

    reg [3:0] phase;
    reg [10:0] capture_index;
    reg [11:0] sample_read_index;
    reg [5:0] bin_index;
    // Pause stops the analyzer, but the display remains active while its
    // separate height smoother fades the current columns down.
    assign spectrum_clear = !music_active;

    // Input storage is 2048 x 8 bits. The audio player continues normally
    // while this analyzer reuses one Goertzel state pair across 64 bins.
    wire [7:0] sample_ram_read_data;
    wire signed [7:0] sample_buffer_read = sample_ram_read_data;
    wire sample_ram_write_enable =
        (phase == ST_CAPTURE) && sample_valid && music_active && !pause_state;
    wire sample_ram_read_enable =
        (phase == ST_BIN_START) ||
        ((phase == ST_PROCESS) && (sample_read_index < 12'd2048));
    wire [10:0] sample_ram_read_address =
        (phase == ST_BIN_START) ? 11'd0 : sample_read_index[10:0];

    // Packed Q16 recurrence and sine coefficients, loaded as a synchronous ROM.
    wire [33:0] coefficient_read_data;

    reg signed [26:0] state1;
    reg signed [26:0] state2;
    reg signed [26:0] multiplier_a;
    reg signed [26:0] multiplier_b;
    wire signed [53:0] multiplier_product =
        $signed(multiplier_a) * $signed(multiplier_b);
    wire signed [26:0] recurrence_term = multiplier_product[42:16];
    wire signed [26:0] sample_extended = {{19{sample_buffer_read[7]}}, sample_buffer_read};
    wire signed [26:0] recurrence_next = sample_extended + recurrence_term - state2;

    wire signed [17:0] goertzel_coefficient = $signed(coefficient_read_data[17:0]);
    wire signed [26:0] coefficient_extended =
        {{9{goertzel_coefficient[17]}}, goertzel_coefficient};
    wire signed [16:0] cosine_coefficient = $signed({1'b0, coefficient_read_data[17:1]});
    wire signed [26:0] cosine_extended = {{10{cosine_coefficient[16]}}, cosine_coefficient};
    wire signed [16:0] sine_coefficient = $signed({1'b0, coefficient_read_data[33:18]});
    wire signed [26:0] sine_extended = {{10{sine_coefficient[16]}}, sine_coefficient};

    reg signed [26:0] real_component;
    reg signed [26:0] imag_component;
    wire real_component_overflow = real_component[26]
                                 ? ((real_component[26:16] != 11'h7ff) ||
                                    (real_component[15:0] == 16'd0))
                                 : (real_component[26:16] != 11'd0);
    wire imag_component_overflow = imag_component[26]
                                 ? ((imag_component[26:16] != 11'h7ff) ||
                                    (imag_component[15:0] == 16'd0))
                                 : (imag_component[26:16] != 11'd0);
    wire [15:0] abs_real_low = real_component[26]
                             ? (~real_component[15:0] + 16'd1) : real_component[15:0];
    wire [15:0] abs_imag_low = imag_component[26]
                             ? (~imag_component[15:0] + 16'd1) : imag_component[15:0];
    wire [15:0] larger_component =
        (abs_real_low > abs_imag_low) ? abs_real_low : abs_imag_low;
    wire [15:0] smaller_component =
        (abs_real_low > abs_imag_low) ? abs_imag_low : abs_real_low;
    // Keep the approximate Goertzel magnitude at full precision until the
    // display mapping; saturate if either component exceeds signed 16-bit range.
    wire [16:0] magnitude_scaled = {1'b0, larger_component}
                                 + {2'b0, smaller_component[15:1]}
                                 - {4'b0, smaller_component[15:3]};
    wire magnitude_above_noise_gate = (magnitude_scaled >= 17'd256);
    wire [3:0] magnitude_level = magnitude_scaled[13:10];
    wire [4:0] magnitude_height_candidate = {1'b0, magnitude_level} + 5'd2;
    wire [3:0] magnitude_height =
        (real_component_overflow || imag_component_overflow || magnitude_scaled[16] ||
         (magnitude_scaled[15:14] != 2'b00))
        ? 4'd15
        : !magnitude_above_noise_gate ? 4'd0
        : magnitude_height_candidate[4] ? 4'd15 : magnitude_height_candidate[3:0];

    bgm_spectrum_coeff_rom u_coefficient_rom (
        .clk(clk),
        .address(bin_index),
        .data(coefficient_read_data)
    );

    bgm_spectrum_sample_ram u_sample_ram (
        .clk(clk),
        .write_enable(sample_ram_write_enable),
        .write_address(capture_index),
        .write_data(bgm_sample),
        .read_enable(sample_ram_read_enable),
        .read_address(sample_ram_read_address),
        .read_data(sample_ram_read_data)
    );

    // One synchronous read/write sample buffer; the BGM audio output itself is
    // never paused while the analyzer walks through the buffered window.
    always @(posedge clk or posedge rst) begin
        if (rst) begin
            phase               <= ST_CAPTURE;
            capture_index       <= 11'd0;
            sample_read_index   <= 12'd0;
            bin_index           <= 6'd0;
            state1              <= 27'sd0;
            state2              <= 27'sd0;
            multiplier_a        <= 27'sd0;
            multiplier_b        <= 27'sd0;
            real_component      <= 27'sd0;
            imag_component      <= 27'sd0;
            height_index        <= 6'd0;
            height_value        <= 4'd0;
            height_valid        <= 1'b0;
            frame_ready         <= 1'b0;
        end else begin
            height_valid <= 1'b0;
            frame_ready <= 1'b0;

            if (!music_active || pause_state) begin
                phase             <= ST_CAPTURE;
                capture_index     <= 11'd0;
                sample_read_index <= 12'd0;
                bin_index         <= 6'd0;
                state1            <= 27'sd0;
                state2            <= 27'sd0;
            end else begin
                case (phase)
                    ST_CAPTURE: begin
                        if (sample_valid) begin
                            if (capture_index == LAST_SAMPLE) begin
                                capture_index <= 11'd0;
                                bin_index <= 6'd0;
                                phase <= ST_BIN_START;
                            end else begin
                                capture_index <= capture_index + 11'd1;
                            end
                        end
                    end

                    ST_BIN_START: begin
                        state1 <= 27'sd0;
                        state2 <= 27'sd0;
                        sample_read_index <= 12'd1;
                        phase <= ST_PROCESS_SETUP;
                    end

                    ST_PROCESS_SETUP: begin
                        multiplier_a <= 27'sd0;
                        multiplier_b <= coefficient_extended;
                        phase <= ST_PROCESS;
                    end

                    ST_PROCESS: begin
                        state1 <= recurrence_next;
                        state2 <= state1;
                        multiplier_a <= recurrence_next;
                        multiplier_b <= coefficient_extended;

                        if (sample_read_index == 12'd2048) begin
                            phase <= ST_FINAL_COS_SETUP;
                        end else begin
                            sample_read_index <= sample_read_index + 12'd1;
                        end
                    end

                    ST_FINAL_COS_SETUP: begin
                        multiplier_a <= state2;
                        multiplier_b <= cosine_extended;
                        phase <= ST_FINAL_COS_CAPTURE;
                    end

                    ST_FINAL_COS_CAPTURE: begin
                        real_component <= state1 - recurrence_term;
                        multiplier_a <= state2;
                        multiplier_b <= sine_extended;
                        phase <= ST_FINAL_SIN_CAPTURE;
                    end

                    ST_FINAL_SIN_CAPTURE: begin
                        imag_component <= recurrence_term;
                        phase <= ST_FINAL_MAGNITUDE;
                    end

                    ST_FINAL_MAGNITUDE: begin
                        height_index <= bin_index;
                        height_value <= magnitude_height;
                        height_valid <= 1'b1;
                        if (bin_index == LAST_BIN) begin
                            frame_ready <= 1'b1;
                            phase <= ST_CAPTURE;
                        end else begin
                            bin_index <= bin_index + 6'd1;
                            phase <= ST_BIN_START;
                        end
                    end

                    default: begin
                        phase <= ST_CAPTURE;
                    end
                endcase
            end
        end
    end
endmodule
