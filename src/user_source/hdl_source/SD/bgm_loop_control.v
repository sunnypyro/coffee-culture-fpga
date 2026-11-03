// Starts the dedicated BGM WAV after the root scan and requests a restart at
// each EOF. An invalid BGM stream is disabled rather than retried forever.
module bgm_loop_control (
    input  wire clk,
    input  wire rst,
    input  wire scan_done,
    input  wire file_found,
    input  wire file_eof,
    input  wire format_error,
    output reg  reader_start,
    output wire bgm_available
);
    reg scan_seen;
    reg reader_started;
    reg eof_seen;
    reg failed;

    assign bgm_available = scan_seen && file_found && !failed;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            scan_seen      <= 1'b0;
            reader_started <= 1'b0;
            eof_seen       <= 1'b0;
            failed         <= 1'b0;
            reader_start   <= 1'b0;
        end else begin
            reader_start <= 1'b0;

            if (scan_done && !scan_seen) begin
                scan_seen <= 1'b1;
                if (file_found && !failed) begin
                    reader_start   <= 1'b1;
                    reader_started <= 1'b1;
                end
            end

            if (reader_started && file_eof && !eof_seen &&
                !failed && !format_error) begin
                reader_start <= 1'b1;
                eof_seen <= 1'b1;
            end

            if (!file_eof)
                eof_seen <= 1'b0;

            if (format_error) begin
                failed <= 1'b1;
                reader_started <= 1'b0;
                eof_seen <= 1'b1;
            end
        end
    end
endmodule
