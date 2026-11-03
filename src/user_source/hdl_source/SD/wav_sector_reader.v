// Reads one standard PCM WAV file through the sector interface.
// The file is addressed through its FAT32 cluster chain, so fragmented
// WAV files are supported. Audio payload is 48 kHz, 16-bit, mono PCM.
module wav_sector_reader (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [31:0] first_data_sector,
    input  wire [31:0] fat_start_sector,
    input  wire [7:0]  sectors_per_cluster,
    input  wire [31:0] file_first_cluster,
    input  wire [31:0] file_size,
    input  wire        abort,

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
    localparam ST_IDLE         = 4'd0;
    localparam ST_WAIT_DATA    = 4'd1;
    localparam ST_READ_DATA    = 4'd2;
    localparam ST_DATA_BASE    = 4'd3;
    localparam ST_READ_FAT     = 4'd4;
    localparam ST_DONE         = 4'd5;
    localparam ST_DATA_OFFSET = 4'd7;
    localparam ST_READ_FAT_GAP = 4'd6;   // FAT -> data transition: one cycle with req low

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


    // 共享 SD 控制器的数据阶段允许 150 ms 并最多重试 4 次；音频扇区还可能
    // 等待当前图像扇区以及 BGM 扇区释放。40 ms 本地期限会抢在共享重试前误报，
    // 随即触发跳图。保留一个有界兜底期限，但给共享读和公平仲裁留下恢复时间。
    // 100 MHz 下 250_000_000 拍 = 2.5 s；超过后仍报错退出，避免永久等待。
    localparam [27:0] WDOG_LIMIT = 28'd250_000_000;

    localparam ST_DATA_END = 4'd8;
    localparam ST_FAT_END = 4'd9;
    localparam ST_FAT_VALIDATE = 4'd10;
    reg [3:0] state;
    reg [27:0] wdog;
    reg        wdog_expire;
    // Predict the terminal count alongside the increment. This has exactly
    // the old equality timing, without its 28-bit decode in every data enable.

    always @(posedge clk or posedge rst) begin
        if (rst || abort || !sd_read_req || sd_read_end) begin
            wdog <= 28'd0;
            wdog_expire <= 1'b0;
        end else if (wdog != WDOG_LIMIT) begin
            wdog <= wdog + 28'd1;
            wdog_expire <= (wdog == WDOG_LIMIT - 28'd1);
        end
    end
    reg [31:0] current_cluster;
    reg [7:0]  sector_in_cluster;
    reg completed_sector_ok;
    reg cluster_has_more;
    always @(posedge clk) cluster_has_more <= sector_in_cluster + 8'd1 < spc_q;
    reg [5:0]  file_byte_count;
    reg [9:0]  sector_byte_count;
    reg [9:0]  fat_byte_count;
    reg [8:0]  fat_entry_byte;
    reg [31:0] fat_next_cluster;
    reg fat_next_valid;
    wire data_sector_complete=(sector_byte_count==10'd512)||((sector_byte_count==10'd511)&&sd_read_data_valid);
    wire fat_sector_complete=(fat_byte_count==10'd512)||((fat_byte_count==10'd511)&&sd_read_data_valid);

    reg [7:0]  sample_low_byte;
    reg        sample_low_valid;
    reg        header_bad;
    reg        pending_file_end;
    reg        restart_pending;
    reg [31:0] bytes_remaining;
    reg file_size_bad;

    function [31:0] cluster_to_sector;
        input [31:0] cluster;
        input [2:0] shift_amount;
        input valid_spc;
        begin
            cluster_to_sector = valid_spc ? ((cluster - 32'd2) << shift_amount) : 32'd0;
        end
    endfunction


    // Preserve the original address-write conditions and priority. Bound the
    // shared enable fanout so TD may place equivalent drivers near the 32 bits.
    (* max_fanout = 8 *) wire address_update_enable =
        !abort && !start && !wdog_expire && !restart_pending &&
        (((state == ST_WAIT_DATA) && fifo_allow_sector) ||
         (state == ST_DATA_BASE) || (state == ST_DATA_OFFSET) ||
         ((state == ST_DATA_END) && completed_sector_ok && !header_bad &&
          !file_size_bad && !sample_low_valid && !pending_file_end && !cluster_has_more));
    always @(posedge clk or posedge rst) begin
        if (rst) sd_read_sector <= 32'd0;
        else if (address_update_enable) begin
            case (state)
                ST_WAIT_DATA: sd_read_sector <= cluster_to_sector(current_cluster,spc_shift,spc_power_of_two);
                ST_DATA_BASE: sd_read_sector <= first_data_sector + sd_read_sector;
                ST_DATA_OFFSET: sd_read_sector <= sd_read_sector + sector_in_cluster;
                ST_DATA_END: sd_read_sector <= fat_start_sector + (current_cluster >> 7);
                default: sd_read_sector <= sd_read_sector;
            endcase
        end
    end

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            bytes_remaining  <= 32'd0;
            file_size_bad    <= 1'b0;
            completed_sector_ok <= 0;
            state            <= ST_IDLE;
            sd_read_req      <= 1'b0;
            current_cluster  <= 32'd0;
            sector_in_cluster<= 8'd0;
            file_byte_count  <= 6'd0;
            sector_byte_count<= 9'd0;
            fat_byte_count   <= 10'd0;
            fat_entry_byte   <= 9'd0;
            fat_next_cluster <= 32'd0;
            fat_next_valid   <= 1'b0;
            sample_low_byte  <= 8'd0;
            sample_low_valid <= 1'b0;
            header_bad       <= 1'b0;
            pending_file_end <= 1'b0;
            restart_pending  <= 1'b0;
            sample_wr_en     <= 1'b0;
            sample_wr_data   <= 16'd0;
            file_eof         <= 1'b0;
            format_error     <= 1'b0;
        end else if (abort) begin
            state            <= ST_IDLE;
            sd_read_req      <= 1'b0;
            sample_low_valid <= 1'b0;
            pending_file_end <= 1'b0;
            restart_pending  <= 1'b0;
            sample_wr_en     <= 1'b0;
            file_eof         <= 1'b0;
            format_error     <= 1'b0;
        end else if (start) begin
            bytes_remaining <= file_size;
            file_size_bad <= file_size < 32'd44;
            // A committed photo selects a new paired WAV. Drop any not-yet-
            // written sample from the old track, but let its active physical
            // sector finish before changing the reader's byte/cluster state.
            restart_pending  <= 1'b1;
            sample_low_valid <= 1'b0;
            pending_file_end <= 1'b0;
            sample_wr_en     <= 1'b0;
            file_eof         <= 1'b0;
            format_error     <= 1'b0;
            if (sd_read_req && sd_read_end) begin
                sd_read_req <= 1'b0;
                state       <= ST_IDLE;
            end
        end else if (wdog_expire) begin
            // Keep the sector timeout active while a track switch waits for
            // the old physical transaction to drain.
            sd_read_req      <= 1'b0;
            sample_wr_en <= 1'b0;
            format_error     <= 1'b1;
            restart_pending  <= 1'b0;
            state            <= ST_DONE;
        end else if (restart_pending) begin
            sample_wr_en <= 1'b0;
            if (sd_read_req) begin
                if (sd_read_end) begin
                    sd_read_req <= 1'b0;
                    state       <= ST_IDLE;
                end
            end else begin
                current_cluster    <= file_first_cluster;
                sector_in_cluster  <= 8'd0;
                file_byte_count    <= 6'd0;
                sector_byte_count  <= 9'd0;
                fat_byte_count     <= 9'd0;
                fat_entry_byte     <= 9'd0;
                fat_next_cluster   <= 32'd0;
                sample_low_valid   <= 1'b0;
                header_bad         <= 1'b0;
                pending_file_end   <= 1'b0;
                file_eof           <= 1'b0;
                format_error       <= 1'b0;
                restart_pending    <= 1'b0;
                state              <= ST_WAIT_DATA;
            end
        end else begin
            sample_wr_en <= 1'b0;
            case (state)
                ST_IDLE: begin
                    // file_eof is deliberately left asserted here: it is only a
                    // couple of cycles wide in this 100 MHz domain and would be
                    // lost when crossing into the 12 MHz audio domain (the
                    // player's synchroniser cannot see a pulse shorter than one
                    // of its own periods).  The player latches it instead, and
                    // this flag is cleared when a new track starts.
                    format_error <= 1'b0;
                    if (start) begin
                        file_eof          <= 1'b0;
                        current_cluster   <= file_first_cluster;
                        sector_in_cluster <= 8'd0;
                        file_byte_count   <= 6'd0;
                        sector_byte_count <= 10'd0;
                        sample_low_valid  <= 1'b0;
                        header_bad        <= 1'b0;
                        pending_file_end  <= 1'b0;
                        state             <= ST_WAIT_DATA;
                    end
                end

                ST_WAIT_DATA: begin
                    if (fifo_allow_sector) begin
                        // Address is private until sd_read_req is asserted.
                        // Reuse its register across subtract/shift, base and offset.
                        sector_byte_count <= 10'd0;
                        state <= ST_DATA_BASE;
                    end
                end

                ST_DATA_BASE: begin
                    state <= ST_DATA_OFFSET;
                end
                ST_DATA_OFFSET: begin
                    sd_read_req <= 1'b1;
                    state <= ST_READ_DATA;
                end

                ST_READ_DATA: begin
                    if (sd_read_data_valid) begin
                        if (bytes_remaining != 0) begin
                            // Validate the fixed fields of a standard PCM WAV header.
                            case (file_byte_count)
                                32'd0:  if (sd_read_data != "R") header_bad <= 1'b1;
                                32'd1:  if (sd_read_data != "I") header_bad <= 1'b1;
                                32'd2:  if (sd_read_data != "F") header_bad <= 1'b1;
                                32'd3:  if (sd_read_data != "F") header_bad <= 1'b1;
                                32'd8:  if (sd_read_data != "W") header_bad <= 1'b1;
                                32'd9:  if (sd_read_data != "A") header_bad <= 1'b1;
                                32'd10: if (sd_read_data != "V") header_bad <= 1'b1;
                                32'd11: if (sd_read_data != "E") header_bad <= 1'b1;
                                32'd20: if (sd_read_data != 8'd1) header_bad <= 1'b1;
                                32'd21: if (sd_read_data != 8'd0) header_bad <= 1'b1;
                                32'd22: if (sd_read_data != 8'd1) header_bad <= 1'b1;
                                32'd23: if (sd_read_data != 8'd0) header_bad <= 1'b1;
                                32'd24: if (sd_read_data != 8'h80) header_bad <= 1'b1;
                                32'd25: if (sd_read_data != 8'hbb) header_bad <= 1'b1;
                                32'd26: if (sd_read_data != 8'd0) header_bad <= 1'b1;
                                32'd27: if (sd_read_data != 8'd0) header_bad <= 1'b1;
                                32'd34: if (sd_read_data != 8'd16) header_bad <= 1'b1;
                                32'd35: if (sd_read_data != 8'd0) header_bad <= 1'b1;
                                32'd36: if (sd_read_data != "d") header_bad <= 1'b1;
                                32'd37: if (sd_read_data != "a") header_bad <= 1'b1;
                                32'd38: if (sd_read_data != "t") header_bad <= 1'b1;
                                32'd39: if (sd_read_data != "a") header_bad <= 1'b1;
                                default: ;
                            endcase

                            if (file_byte_count >= 32'd44) begin
                                if (!sample_low_valid) begin
                                    sample_low_byte  <= sd_read_data;
                                    sample_low_valid <= 1'b1;
                                end else begin
                                    sample_low_valid <= 1'b0;
                                    if (!header_bad) begin
                                        sample_wr_en   <= 1'b1;
                                        sample_wr_data <= {sd_read_data, sample_low_byte};
                                    end
                                end
                            end

                            if (file_byte_count < 6'd44)
                                file_byte_count <= file_byte_count + 6'd1;
                            bytes_remaining <= bytes_remaining - 32'd1;
                            if (bytes_remaining == 32'd1)
                                pending_file_end <= 1'b1;
                        end
                        sector_byte_count <= sector_byte_count + 9'd1;
                    end

                    if (sd_read_end) begin
                        sd_read_req <= 0;
                        completed_sector_ok <= data_sector_complete;
                        state <= ST_DATA_END;
                    end
                end

                ST_READ_FAT: begin
                    if (sd_read_data_valid) begin
                        if (fat_byte_count == fat_entry_byte)
                            fat_next_cluster[7:0] <= sd_read_data;
                        else if (fat_byte_count == fat_entry_byte + 9'd1)
                            fat_next_cluster[15:8] <= sd_read_data;
                        else if (fat_byte_count == fat_entry_byte + 9'd2)
                            fat_next_cluster[23:16] <= sd_read_data;
                        else if (fat_byte_count == fat_entry_byte + 9'd3)
                            fat_next_cluster[31:24] <= sd_read_data;
                        fat_byte_count <= fat_byte_count + 10'd1;
                    end
                    if (sd_read_end) begin
                        sd_read_req <= 0;
                        completed_sector_ok <= fat_sector_complete;
                        state <= ST_FAT_END;
                    end
                end

                ST_READ_FAT_GAP: begin
                    // 请求低电平一拍已经过去，地址在上面那拍就设好了，现在发请求
                    sd_read_req <= 1'b1;
                    state       <= ST_READ_FAT;
                end

                // Commit one cycle after byte 512 so tail PCM/header/FAT registers settle.
                ST_DATA_END: begin
                    sd_read_req <= 1'b0;
                    if (!completed_sector_ok || header_bad || (file_size_bad) || sample_low_valid) begin
                        format_error <= 1'b1;
                        state        <= ST_DONE;
                    end else if (pending_file_end) begin
                        file_eof <= 1'b1;
                        state    <= ST_DONE;
                    end else if (cluster_has_more) begin
                        sector_in_cluster <= sector_in_cluster + 8'd1;
                        state             <= ST_WAIT_DATA;
                    end else begin
                        // FAT32 entry: four bytes, at cluster*4 in its FAT sector.
                        fat_byte_count   <= 10'd0;
                        fat_entry_byte   <= {current_cluster[6:0], 2'b00};
                        fat_next_cluster <= 32'd0;
                        // 这里刻意让请求保持低电平一拍，下一拍（ST_READ_FAT_GAP）
                        // 再拉高。与已经上板跑通的 bmp_read 的取扇区写法一致：
                        // 新地址先稳定，再发出请求。原来这里直接把请求保持为高，
                        // 是整份代码里唯一一处这样写的取扇区路径。
                        sd_read_req      <= 1'b0;
                        state            <= ST_READ_FAT_GAP;
                    end
                end

                ST_FAT_END: begin
                    sd_read_req <= 1'b0;
                    // Byte 511 may contain the last FAT byte together with end.
                    // Validate its settled value, then update control next cycle.
                    fat_next_valid <= completed_sector_ok &&
                        (fat_next_cluster[27:0] >= 28'd2) &&
                        (fat_next_cluster[27:0] < 28'hffffff8);
                    state <= ST_FAT_VALIDATE;
                end

                ST_FAT_VALIDATE: begin
                    sd_read_req <= 1'b0;
                    if (!fat_next_valid) begin
                        format_error <= 1'b1;
                        state        <= ST_DONE;
                    end else begin
                        current_cluster   <= {4'd0, fat_next_cluster[27:0]};
                        sector_in_cluster <= 8'd0;
                        state             <= ST_WAIT_DATA;
                    end
                end

                ST_DONE: begin
                    sd_read_req <= 1'b0;
                    // Manual mode may restart the same file immediately after
                    // the previous playback reached EOF. Treat this pulse as
                    // a fresh track start instead of waiting through IDLE.
                    if (start) begin
                        current_cluster   <= file_first_cluster;
                        sector_in_cluster <= 8'd0;
                        file_byte_count   <= 6'd0;
                        sector_byte_count <= 10'd0;
                        sample_low_valid  <= 1'b0;
                        header_bad        <= 1'b0;
                        pending_file_end  <= 1'b0;
                        file_eof          <= 1'b0;
                        format_error      <= 1'b0;
                        state             <= ST_WAIT_DATA;
                    end else begin
                        state <= ST_IDLE;
                    end
                end

                default: begin
                    state       <= ST_IDLE;
                    sd_read_req <= 1'b0;
                end
            endcase
        end
    end
endmodule
