// Lean FAT32 WAV reader for the fixed mono, 48 kHz, 16-bit BGM asset.
// The narration path keeps using the fully featured wav_sector_reader.
// SD retries are handled by the shared sector controller; this reader keeps
// FAT-chain traversal and omits header parsing because the BGM asset is fixed.
module secret_base_bgm_sector_reader #(
    parameter [22:0] FILE_SIZE_BYTES = 23'd4_848_044
) (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [31:0] first_data_sector,
    input  wire [31:0] fat_start_sector,
    input  wire [7:0]  sectors_per_cluster,
    input  wire [27:0] file_first_cluster,

    output reg         sd_read_req,
    output reg [31:0]  sd_read_sector,
    input  wire [7:0]  sd_read_data,
    input  wire        sd_read_data_valid,
    input  wire        sd_read_end,

    input  wire        fifo_allow_sector,
    output reg         sample_wr_en,
    output reg [15:0]  sample_wr_data,
    output reg         file_eof,
    output reg         format_error
);
    localparam ST_IDLE         = 3'd0;
    localparam ST_WAIT_DATA    = 3'd1;
    localparam ST_READ_DATA    = 3'd2;
    localparam ST_READ_FAT     = 3'd3;
    localparam ST_READ_FAT_GAP = 3'd4;
    localparam ST_DONE         = 3'd5;
    localparam ST_SECTOR_END = 3'd7;
    reg completed_fat;
    localparam ST_DATA_BASE    = 3'd6;

    localparam [13:0] DATA_SECTOR_COUNT = (FILE_SIZE_BYTES + 23'd511) >> 9;
    localparam [13:0] LAST_DATA_SECTOR = DATA_SECTOR_COUNT - 14'd1;
    localparam [9:0] LAST_SECTOR_BYTES =
        (FILE_SIZE_BYTES[8:0] == 9'd0) ? 10'd512 : {1'b0, FILE_SIZE_BYTES[8:0]};

    // 2026-10-23：sectors_per_cluster 是 FAT 扫描完成后的静态量，
    // 但它是全芯片扇出 48 的高扇出线，被当成移位选择/比较量时单条 net
    // 就能吃掉 4~5ns（sd_card_clk 100MHz 只有 10ns 预算）。
    // 在模块入口先打一拍，长线到此为止；只影响上电后头 1 拍，功能无影响。
    reg [7:0] spc_q;
    always @(posedge clk) spc_q <= sectors_per_cluster;
    // Geometry is stable before any sector request. Register its decode
    // separately from the 32-bit address shift to cut the high-fanout cone.
    reg [2:0] spc_shift;
    reg spc_power_of_two;
    always @(posedge clk) begin
        spc_power_of_two <= 1'b1;
        case (sectors_per_cluster)
            8'd1: spc_shift <= 3'd0;
            8'd2: spc_shift <= 3'd1;
            8'd4: spc_shift <= 3'd2;
            8'd8: spc_shift <= 3'd3;
            8'd16: spc_shift <= 3'd4;
            8'd32: spc_shift <= 3'd5;
            8'd64: spc_shift <= 3'd6;
            8'd128: spc_shift <= 3'd7;
            default: begin spc_shift <= 3'd0; spc_power_of_two <= 1'b0; end
        endcase
    end


    localparam ST_FAT_VALIDATE = 4'd8;
    reg fat_next_valid;
    reg [3:0]  state;
    reg [27:0] current_cluster;
    reg [7:0]  sector_in_cluster;
    reg completed_sector_ok;
    reg cluster_has_more;
    always @(posedge clk) cluster_has_more <= sector_in_cluster + 8'd1 < spc_q;
    reg [13:0] data_sector_index;
    // Data and FAT reads are mutually exclusive, so they share one byte counter.
    // The tenth bit distinguishes a complete 512-byte sector from a short read.
    reg [9:0]  sector_byte_count;
    reg [6:0]  fat_entry_index;
    reg [7:0]  sample_low_byte;
    reg        sample_low_valid;

    wire is_first_data_sector = (data_sector_index == 14'd0);
    wire is_last_data_sector = (data_sector_index == LAST_DATA_SECTOR);
    wire file_payload_byte = (!is_first_data_sector || (sector_byte_count >= 10'd44)) &&
                             (!is_last_data_sector ||
                              (sector_byte_count < LAST_SECTOR_BYTES));
    wire sector_complete = (sector_byte_count == 10'd512) ||
                           ((sector_byte_count == 10'd511) && sd_read_data_valid);

    function [31:0] cluster_to_sector;
        input [27:0] cluster;
        input [2:0] shift_amount;
        reg [31:0] cluster_offset;
        begin
            cluster_offset = {4'd0,cluster} - 32'd2;
            cluster_to_sector = cluster_offset << shift_amount;
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            completed_sector_ok <= 0;completed_fat <= 0;
            fat_next_valid <= 1'b0;
            state                 <= ST_IDLE;
            sd_read_req           <= 1'b0;
            sd_read_sector        <= 32'd0;
            current_cluster       <= 28'd0;
            sector_in_cluster     <= 8'd0;
            data_sector_index     <= 14'd0;
            sector_byte_count     <= 10'd0;
            fat_entry_index       <= 7'd0;
            sample_low_byte       <= 8'd0;
            sample_low_valid      <= 1'b0;
            sample_wr_en          <= 1'b0;
            sample_wr_data        <= 16'd0;
            file_eof              <= 1'b0;
            format_error          <= 1'b0;
        end else begin
            sample_wr_en <= 1'b0;
            case (state)
                ST_IDLE: begin
                    format_error <= 1'b0;
                    if (start) begin
                        file_eof         <= 1'b0;
                        sample_low_valid <= 1'b0;
                        if ((file_first_cluster < 28'd2) ||
                            (FILE_SIZE_BYTES < 23'd46) || FILE_SIZE_BYTES[0]) begin
                            format_error <= 1'b1;
                            state        <= ST_DONE;
                        end else begin
                            current_cluster        <= file_first_cluster;
                            sector_in_cluster      <= 8'd0;
                            data_sector_index      <= 14'd0;
                            sector_byte_count      <= 10'd0;
                            sd_read_sector <= cluster_to_sector(file_first_cluster,spc_shift);
                            state <= ST_DATA_BASE;
                        end
                    end
                end

                // Reuse the request address register as the cluster offset.
                // The base addition is isolated before requesting the sector.
                ST_DATA_BASE: begin
                    sd_read_sector <= first_data_sector + sd_read_sector;
                    state <= ST_WAIT_DATA;
                end

                ST_WAIT_DATA: begin
                    if (fifo_allow_sector) begin
                        sd_read_req <= 1'b1;
                        sector_byte_count <= 10'd0;
                        state       <= ST_READ_DATA;
                    end
                end

                ST_READ_DATA: begin
                    if (sd_read_data_valid) begin
                        sector_byte_count <= sector_byte_count + 10'd1;
                        if (file_payload_byte) begin
                            if (!sample_low_valid) begin
                                sample_low_byte  <= sd_read_data;
                                sample_low_valid <= 1'b1;
                            end else begin
                                sample_low_valid <= 1'b0;
                                sample_wr_en     <= 1'b1;
                                sample_wr_data   <= {sd_read_data, sample_low_byte};
                            end
                        end
                    end

                    if (sd_read_end) begin
                        sd_read_req <= 0;
                        completed_sector_ok <= sector_complete;
                        completed_fat <= 1'b0;
                        state <= ST_SECTOR_END;
                    end
                end

                ST_READ_FAT_GAP: begin
                    sd_read_req <= 1'b1;
                    state       <= ST_READ_FAT;
                end

                ST_READ_FAT: begin
                    if (sd_read_data_valid) begin
                        if (sector_byte_count[8:2] == fat_entry_index) begin
                            case (sector_byte_count[1:0])
                                2'd0: current_cluster[7:0]   <= sd_read_data;
                                2'd1: current_cluster[15:8]  <= sd_read_data;
                                2'd2: current_cluster[23:16] <= sd_read_data;
                                2'd3: current_cluster[27:24] <= sd_read_data[3:0];
                            endcase
                        end
                        sector_byte_count <= sector_byte_count + 10'd1;
                    end

                    if (sd_read_end) begin
                        sd_read_req <= 0;
                        completed_sector_ok <= sector_complete;
                        completed_fat <= 1'b1;
                        state <= ST_SECTOR_END;
                    end
                end

                // Tail-byte updates must settle before EOF/FAT and address decisions.
                ST_SECTOR_END: begin
                    if (completed_fat) begin
                        sd_read_req <= 1'b0;
                        // Settle the final FAT byte, then separate range checking
                        // from the wide address/control update on the next cycle.
                        fat_next_valid <= completed_sector_ok &&
                            (current_cluster >= 28'd2) &&
                            (current_cluster < 28'hffffff8);
                        state <= ST_FAT_VALIDATE;
                    end else begin
                        sd_read_req <= 1'b0;
                        if (!completed_sector_ok) begin
                            format_error     <= 1'b1;
                            sample_low_valid <= 1'b0;
                            state            <= ST_DONE;
                        end else if (is_last_data_sector) begin
                            if (sample_low_valid) begin
                                format_error <= 1'b1;
                            end else begin
                                file_eof <= 1'b1;
                            end
                            state <= ST_DONE;
                        end else begin
                            data_sector_index <= data_sector_index + 14'd1;
                            if (cluster_has_more) begin
                                sector_in_cluster <= sector_in_cluster + 8'd1;
                                sd_read_sector    <= sd_read_sector + 32'd1;
                                state             <= ST_WAIT_DATA;
                            end else begin
                                sector_byte_count <= 10'd0;
                                fat_entry_index  <= current_cluster[6:0];
                                sd_read_sector   <= fat_start_sector +
                                                    (current_cluster >> 7);
                                state            <= ST_READ_FAT_GAP;
                            end
                        end
                    end
                end

                ST_FAT_VALIDATE: begin
                    sd_read_req <= 1'b0;
                    if (!fat_next_valid) begin
                        format_error <= 1'b1;
                        state <= ST_DONE;
                    end else begin
                        sector_in_cluster <= 8'd0;
                        sd_read_sector <= cluster_to_sector(current_cluster,spc_shift);
                        state <= ST_DATA_BASE;
                    end
                end

                ST_DONE: begin
                    sd_read_req <= 1'b0;
                    if (start) begin
                        file_eof          <= 1'b0;
                        format_error      <= 1'b0;
                        sample_low_valid  <= 1'b0;
                        if ((file_first_cluster < 28'd2) ||
                            (FILE_SIZE_BYTES < 23'd46) || FILE_SIZE_BYTES[0]) begin
                            format_error <= 1'b1;
                            state        <= ST_IDLE;
                        end else begin
                            current_cluster        <= file_first_cluster;
                            sector_in_cluster      <= 8'd0;
                            data_sector_index      <= 14'd0;
                            sector_byte_count      <= 10'd0;
                            sd_read_sector <= cluster_to_sector(file_first_cluster,spc_shift);
                            state <= ST_DATA_BASE;
                        end
                    end else begin
                        state <= ST_IDLE;
                    end
                end

                default: begin
                    sd_read_req <= 1'b0;
                    state       <= ST_IDLE;
                end
            endcase
        end
    end
endmodule
