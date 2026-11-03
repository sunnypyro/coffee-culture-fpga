// Dedicated streamed mono PCM source for the Secret Base background track.
// The FIFO is deliberately reset only by the system reset, so image and
// narration-track changes cannot restart or interrupt the background stream.
module secret_base_bgm_stream #(
    parameter [22:0] FILE_SIZE_BYTES = 23'd4_848_044
) (
    input  wire        sd_clk,
    input  wire        sample_clk,
    input  wire        rst,
    input  wire        scan_done,
    input  wire [31:0] first_data_sector,
    input  wire [31:0] fat_start_sector,
    input  wire [7:0]  sectors_per_cluster,
    input  wire [27:0] file_first_cluster,

    output wire        bgm_sd_req,
    output wire [31:0] bgm_sd_sector,
    input  wire [7:0]  bgm_sd_data,
    input  wire        bgm_sd_data_valid,
    input  wire        bgm_sd_end,

    input  wire        sample_tick,
    input  wire        playback_enable,
    input  wire        pause_state,
    output wire        bgm_available,
    output wire        bgm_sample_valid,
    output wire signed [15:0] bgm_sample
);
    wire reader_start;
    wire file_eof;
    wire format_error;
    wire sample_wr_en;
    wire [15:0] sample_wr_data;
    wire fifo_empty;
    wire [8:0] fifo_wrusedw;
    wire [15:0] fifo_dout;

    wire file_found = (file_first_cluster >= 28'd2);

    bgm_loop_control u_bgm_loop_control (
        .clk          (sd_clk),
        .rst          (rst),
        .scan_done    (scan_done),
        .file_found   (file_found),
        .file_eof     (file_eof),
        .format_error (format_error),
        .reader_start (reader_start),
        .bgm_available(bgm_available)
    );

    secret_base_bgm_sector_reader #(
        .FILE_SIZE_BYTES(FILE_SIZE_BYTES)
    ) u_bgm_sector_reader (
        .clk                (sd_clk),
        .rst                (rst),
        .start              (reader_start),
        .first_data_sector  (first_data_sector),
        .fat_start_sector   (fat_start_sector),
        .sectors_per_cluster(sectors_per_cluster),
        .file_first_cluster (file_first_cluster),
        .sd_read_req        (bgm_sd_req),
        .sd_read_sector     (bgm_sd_sector),
        .sd_read_data       (bgm_sd_data),
        .sd_read_data_valid (bgm_sd_data_valid),
        .sd_read_end        (bgm_sd_end),
        .fifo_allow_sector  (fifo_wrusedw < 9'd256),
        .sample_wr_en       (sample_wr_en),
        .sample_wr_data     (sample_wr_data),
        .file_eof           (file_eof),
        .format_error       (format_error)
    );

    assign bgm_sample_valid = sample_tick && playback_enable &&
                              !pause_state && !fifo_empty;
    assign bgm_sample = $signed(fifo_dout);

    audio_fifo_16 u_bgm_fifo (
        .rst        (rst),
        .clkw       (sd_clk),
        .clkr       (sample_clk),
        .we         (sample_wr_en),
        .di         (sample_wr_data),
        .re         (bgm_sample_valid),
        .dout       (fifo_dout),
        .valid      (),
        .full_flag  (),
        .empty_flag (fifo_empty),
        .afull      (),
        .aempty     (),
        .wrusedw    (fifo_wrusedw),
        .rdusedw    ()
    );
endmodule
