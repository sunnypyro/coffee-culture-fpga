module bmp_read(
    input                       clk,
    input                       rst,
    output                      ready,

    // 上电扫描：从 scan_start_sector 开始，顺序寻找前 scan_target_count 张 BMP
    input                       scan_start,
    input  [31:0]               scan_start_sector,
    input  [31:0]               scan_max_sector,
    input  [2:0]                scan_target_count,
    output reg                  scan_done,
    output reg                  scan_found_valid,
    output reg [31:0]           scan_found_sector,
    output reg [2:0]            scan_found_total,

    // 按指定扇区加载一张图到 SDRAM
    input abort_req,
    input img_inflight,
    output reg abort_done,
    input                       load_start,
    input  [31:0]               load_sector,

    input                       sd_init_done,
    output reg                  load_failed,
    output reg [3:0]            state_code,
    input  [15:0]               bmp_width,
    input  [15:0]               bmp_height,
    output reg [15:0]           img_width,
    output reg [15:0]           img_height,
    output reg                  data_start,
    // Raw dimensions of the accepted BMP header; held stable with a toggle
    // for the video-clock domain to capture as a bundled-data CDC.
    output reg [15:0]           hdr_width,
    output reg [15:0]           hdr_height,
    output reg                  hdr_toggle,

    output reg                  write_req,
    input                       write_req_ack,

    output reg                  sd_sec_read,
    output reg [31:0]           sd_sec_read_addr,
    input  [7:0]                sd_sec_read_data,
    input                       sd_sec_read_data_valid,
    input                       sd_sec_read_end,
    input                       bmp_data_ready,

    output reg                  bmp_data_wr_en,
    output reg [23:0]           bmp_data
);

localparam ST_IDLE      = 3'd0;
localparam ST_SCAN      = 3'd1;
localparam ST_LOAD_HDR  = 3'd2;
localparam ST_LOAD_WAIT = 3'd3;
localparam ST_LOAD_DATA = 3'd4;
localparam ST_ABORT_WAIT=3'd5;
reg[2:0]abort_guard;
always @(posedge clk or posedge rst)begin
 if(rst)abort_guard<=0;
 else if(!abort_req||img_inflight||sd_sec_read)abort_guard<=0;
 else if(abort_guard<5)abort_guard<=abort_guard+1'b1;
end

reg [2:0]  state;
reg [9:0]  rd_cnt;
reg [9:0] data_received;
wire header_sector_complete = !sd_sec_read_data_valid ? rd_cnt==10'd512 : rd_cnt==10'd511;
wire data_sector_complete = !sd_sec_read_data_valid ? data_received==10'd512 : data_received==10'd511;
reg [11:0] length_height;
reg [31:0] length_addend, length_sum;
reg [3:0] length_steps;
reg length_valid;
wire [31:0] length_sum_next = length_sum + (length_height[0] ? length_addend : 32'd0);
    // ------------------------------------------------------------------
    // 等帧缓存写通道应答的超时（2026-09-16 新增）
    // ST_LOAD_WAIT 原来只等 write_req_ack，没有任何上限：帧通路的握手只要丢一次，
    // 这里就永久挂住 ⇒ 上层 sd_card_bmp 的 load_busy 永远清不掉 ⇒ 整机卡死。
    // 100 ms = 10_000_000 拍 @100 MHz。
    // ------------------------------------------------------------------
    localparam [23:0] ACK_TIMEOUT = 24'd10_000_000;
    reg  [23:0] ack_to_cnt;
    wire        ack_to = (ack_to_cnt == ACK_TIMEOUT);

    always @(posedge clk or posedge rst) begin
        if (rst)
            ack_to_cnt <= 24'd0;
        else if (state != ST_LOAD_WAIT)
            ack_to_cnt <= 24'd0;
        else if (!ack_to)
            ack_to_cnt <= ack_to_cnt + 24'd1;
    end

reg [7:0]  header_0;
reg [7:0]  header_1;
reg [23:0] file_len;
reg [23:0] file_last_index;
// The accepted file length is stable long before pixel parsing starts.
// Move subtraction to header setup instead of adding in every byte decision.
always @(posedge clk or posedge rst) begin
 if(rst)file_last_index<=0;
 else if((state==ST_SCAN || state==ST_LOAD_HDR) && sd_sec_read_data_valid && rd_cnt==34)
  file_last_index<=file_len-24'd1;
end
reg [23:0] pixel_offset;
reg        file_len_hi_nonzero;
reg        pixel_offset_hi_nonzero;
reg [15:0] width;
reg [15:0] height;
reg        width_hi_nonzero;
reg        height_hi_nonzero;
reg [15:0] bit_count;
reg        compression_nonzero;

reg [31:0] scan_sector;
reg [31:0] load_sector_latched;
reg [23:0] bmp_len_cnt;
reg [1:0]  bmp_byte_idx;
reg [15:0] col_px;
reg [15:0] row_px;
reg [1:0]  pad_left;
reg [8:0]  sector_wr_addr;
reg [8:0]  sector_rd_addr;
reg        sector_loading;
reg        sector_full;
reg        sector_read_pending;
reg        sector_byte_valid;
reg [7:0]  sector_byte_q;

wire header_match_raw;
reg header_match;
reg header_offset_valid;
reg byte_in_image_q,byte_final_q,byte_more_q,column_last_q;
reg file_consumed;

// Header fields are complete hundreds of clocks before sector end. Byte
// metadata is captured during the synchronous BRAM read wait, before valid.
always @(posedge clk or posedge rst)begin
 if(rst)begin header_offset_valid<=0;header_match<=0;byte_in_image_q<=0;byte_final_q<=0;byte_more_q<=0;column_last_q<=0;end
 else begin
  header_offset_valid <= pixel_offset < file_len;
  header_match<=header_match_raw;
  if(sector_read_pending)begin
   byte_in_image_q<=(bmp_len_cnt>=pixel_offset)&&(bmp_len_cnt<file_len)&&(row_px<height);
   byte_final_q<=(bmp_len_cnt>=file_last_index);
   byte_more_q<=(bmp_len_cnt<file_last_index);
   column_last_q<=(col_px==(width-16'd1));
  end
 end
end
wire dims_ok;
wire bmp_data_valid;
wire [1:0] row_pad_bytes;
wire sector_write_en;
wire sector_read_request;
wire sector_byte_can_consume;
wire sector_last_byte_consume;
wire final_file_byte_consume;
wire need_sector_read;
wire source_read_done;
wire [7:0] sector_ram_q;
wire [24:0] file_len_rounded = {1'b0, file_len} + 25'd511;
wire [31:0] file_sector_count;
wire [31:0] next_scan_sector_if_match;
wire [31:0] next_scan_sector_if_miss;

// Start after stable header fields; twelve shift/add clocks and a separate
// comparison clock. Complete well before the end of the 512-byte header; no DSP.
always @(posedge clk or posedge rst) begin
 if(rst) begin length_height<=0;length_addend<=0;length_sum<=0;length_steps<=0;length_valid<=0;end
 else if(state!=ST_SCAN && state!=ST_LOAD_HDR) begin length_steps<=0;length_valid<=0;end
 else if(sd_sec_read_end) begin length_steps<=0;length_valid<=0;end
 else if(sd_sec_read_data_valid && rd_cnt==0) begin length_steps<=0;length_valid<=0;end
 else if(sd_sec_read_data_valid && rd_cnt==34) begin
  length_height<=height[11:0];
  length_addend<=(({16'd0,width}<<1)+{16'd0,width}+32'd3)&32'hfffffffc;
  length_sum<={8'd0,pixel_offset};length_steps<=13;length_valid<=0;
 end else if(length_steps!=0) begin
  length_steps<=length_steps-1'b1;
  if(length_steps==1)length_valid<=length_sum<={8'd0,file_len};
  else begin
   length_sum<=length_sum_next;length_height<=length_height>>1;length_addend<=length_addend<<1;
  end
 end
end
always @(posedge clk or posedge rst) begin
 if(rst)data_received<=0;
 else if(state!=ST_LOAD_DATA || need_sector_read)data_received<=0;
 else if(sector_write_en && data_received<10'd513)data_received<=data_received+1'b1;
end


assign ready = (state == ST_IDLE);
assign dims_ok = !width_hi_nonzero && !height_hi_nonzero &&
                 (width >= 16'd1) && (width <= 16'd1024) &&
                 (height >= 16'd1) && (height <= 16'd2048);
assign header_match_raw = (header_0 == "B") &&
                      (header_1 == "M") &&
                      dims_ok &&
                      (bit_count    == 16'd24) &&
                      !compression_nonzero &&
                      !file_len_hi_nonzero &&
                      !pixel_offset_hi_nonzero &&
                      header_offset_valid && length_valid;
assign bmp_data_valid = sector_byte_valid && byte_in_image_q;
assign row_pad_bytes = width[1:0];
assign sector_write_en = (state == ST_LOAD_DATA) && sector_loading && sd_sec_read_data_valid;
assign sector_read_request = (state == ST_LOAD_DATA) && sector_full &&
                             !sector_read_pending && !sector_byte_valid &&
                             (!bmp_data_wr_en || bmp_data_ready) &&
                             !file_consumed;
assign sector_byte_can_consume = sector_byte_valid &&
                                 (!bmp_data_wr_en || bmp_data_ready);
assign sector_last_byte_consume = sector_byte_can_consume &&
                                  (sector_rd_addr == 9'd511);
assign final_file_byte_consume = sector_byte_can_consume &&
                                 byte_final_q;
assign need_sector_read = (state == ST_LOAD_DATA) && !sector_loading &&
                          !sector_full && !sector_read_pending &&
                          !sector_byte_valid && !file_consumed;
assign source_read_done = file_consumed && !bmp_data_wr_en &&
                          !sector_byte_valid && !sector_read_pending &&
                          !sector_loading && !sector_full;

always @(posedge clk or posedge rst)begin
 if(rst)file_consumed<=0;
 else if(state!=ST_LOAD_DATA)file_consumed<=0;
 else if(final_file_byte_consume)file_consumed<=1;
end

EG_LOGIC_BRAM #(
    .DATA_WIDTH_A(8), .ADDR_WIDTH_A(9), .DATA_DEPTH_A(512),
    .DATA_WIDTH_B(8), .ADDR_WIDTH_B(9), .DATA_DEPTH_B(512),
    .MODE("DP"), .REGMODE_A("NOREG"), .REGMODE_B("NOREG"),
    .IMPLEMENT("9K"), .DEBUGGABLE("NO"), .PACKABLE("NO"),
    .INIT_FILE("NONE"), .FILL_ALL("NONE")
) u_bmp_sector_buffer (
    .dia(sd_sec_read_data), .dib(8'd0),
    .addra(sector_wr_addr), .addrb(sector_rd_addr),
    .cea(sector_write_en), .ceb(sector_read_request),
    .ocea(1'b0), .oceb(1'b0), .clka(clk), .clkb(clk),
    .wea(sector_write_en), .web(1'b0), .bea(1'b1), .beb(1'b0),
    .rsta(1'b0), .rstb(1'b0), .doa(), .dob(sector_ram_q)
);

// One SD sector is staged in BRAM before parsing. This lets the reader pause
// between bytes without losing the SD controller's uninterruptible 512-byte
// transfer, and prevents a later sector from overwriting data still in use.
always @(posedge clk or posedge rst) begin
    if (rst) begin
        sector_wr_addr       <= 9'd0;
        sector_rd_addr       <= 9'd0;
        sector_loading       <= 1'b0;
        sector_full          <= 1'b0;
        sector_read_pending  <= 1'b0;
        sector_byte_valid    <= 1'b0;
        sector_byte_q        <= 8'd0;
    end else if (state != ST_LOAD_DATA) begin
        sector_wr_addr       <= 9'd0;
        sector_rd_addr       <= 9'd0;
        sector_loading       <= 1'b0;
        sector_full          <= 1'b0;
        sector_read_pending  <= 1'b0;
        sector_byte_valid    <= 1'b0;
    end else begin
        if (need_sector_read) begin
            sector_loading <= 1'b1;
            sector_wr_addr <= 9'd0;
        end

        if (sector_write_en)
            sector_wr_addr <= sector_wr_addr + 9'd1;

        if (sd_sec_read_end && sector_loading) begin
            sector_loading <= 1'b0;
            sector_full    <= data_sector_complete;
            sector_rd_addr <= 9'd0;
        end

        if (sector_read_request)
            sector_read_pending <= 1'b1;
        else if (sector_read_pending) begin
            sector_read_pending <= 1'b0;
            sector_byte_q       <= sector_ram_q;
            sector_byte_valid   <= 1'b1;
        end

        if (sector_byte_can_consume) begin
            sector_byte_valid <= 1'b0;
            if ((sector_rd_addr == 9'd511) || final_file_byte_consume)
                sector_full <= 1'b0;
            else
                sector_rd_addr <= sector_rd_addr + 9'd1;
        end
    end
end

assign file_sector_count = (file_len == 24'd0) ? 32'd1 : (file_len_rounded >> 9);
assign next_scan_sector_if_match = scan_sector + file_sector_count;
assign next_scan_sector_if_miss  = scan_sector + 32'd1;

always @(posedge clk or posedge rst) begin
    if (rst) begin
        hdr_width  <= 16'd0;
        hdr_height <= 16'd0;
        hdr_toggle <= 1'b0;
        img_width  <= 16'd0;
        img_height <= 16'd0;
    end else if ((state == ST_LOAD_HDR) && sd_sec_read_end && header_sector_complete && header_match) begin
        hdr_width  <= width[15:0];
        hdr_height <= height[15:0];
        hdr_toggle <= ~hdr_toggle;
        img_width  <= width[15:0];
        img_height <= height[15:0];
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        rd_cnt <= 10'd0;
    end else if ((state == ST_SCAN) || (state == ST_LOAD_HDR)) begin
        if (sd_sec_read_end)
            rd_cnt <= 10'd0;
        else if (sd_sec_read_data_valid && rd_cnt < 10'd513)
            rd_cnt <= rd_cnt + 10'd1;
    end else begin
        rd_cnt <= 10'd0;
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        header_0     <= 8'd0;
        header_1     <= 8'd0;
        file_len     <= 24'd0;
        pixel_offset <= 24'd54;
        file_len_hi_nonzero <= 1'b0;
        pixel_offset_hi_nonzero <= 1'b0;
        width        <= 16'd0;
        height       <= 16'd0;
        width_hi_nonzero  <= 1'b0;
        height_hi_nonzero <= 1'b0;
        bit_count    <= 16'd0;
        compression_nonzero <= 1'b0;
    end else if (((state == ST_SCAN) || (state == ST_LOAD_HDR)) && sd_sec_read_data_valid) begin
        if (rd_cnt == 10'd0) begin
            width_hi_nonzero  <= 1'b0;
            height_hi_nonzero <= 1'b0;
            compression_nonzero <= 1'b0;
            file_len_hi_nonzero <= 1'b0;
            pixel_offset_hi_nonzero <= 1'b0;
        end
        case (rd_cnt)
            10'd0 : header_0 <= sd_sec_read_data;
            10'd1 : header_1 <= sd_sec_read_data;

            10'd2 : file_len[7:0] <= sd_sec_read_data;
            10'd3 : file_len[15:8] <= sd_sec_read_data;
            10'd4 : file_len[23:16] <= sd_sec_read_data;
            10'd5 : if (sd_sec_read_data != 8'd0) file_len_hi_nonzero <= 1'b1;

            10'd10: pixel_offset[7:0] <= sd_sec_read_data;
            10'd11: pixel_offset[15:8] <= sd_sec_read_data;
            10'd12: pixel_offset[23:16] <= sd_sec_read_data;
            10'd13: if (sd_sec_read_data != 8'd0) pixel_offset_hi_nonzero <= 1'b1;

            10'd18: width[7:0] <= sd_sec_read_data;
            10'd19: width[15:8] <= sd_sec_read_data;
            10'd20: if (sd_sec_read_data != 8'd0) width_hi_nonzero <= 1'b1;
            10'd21: if (sd_sec_read_data != 8'd0) width_hi_nonzero <= 1'b1;

            10'd22: height[7:0] <= sd_sec_read_data;
            10'd23: height[15:8] <= sd_sec_read_data;
            10'd24: if (sd_sec_read_data != 8'd0) height_hi_nonzero <= 1'b1;
            10'd25: if (sd_sec_read_data != 8'd0) height_hi_nonzero <= 1'b1;

            10'd28: bit_count[7:0] <= sd_sec_read_data;
            10'd29: bit_count[15:8] <= sd_sec_read_data;

            10'd30: if (sd_sec_read_data != 8'd0) compression_nonzero <= 1'b1;
            10'd31: if (sd_sec_read_data != 8'd0) compression_nonzero <= 1'b1;
            10'd32: if (sd_sec_read_data != 8'd0) compression_nonzero <= 1'b1;
            10'd33: if (sd_sec_read_data != 8'd0) compression_nonzero <= 1'b1;
            default: ;
        endcase
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        bmp_len_cnt     <= 24'd0;
        bmp_byte_idx    <= 2'd0;
        col_px          <= 16'd0;
        row_px          <= 16'd0;
        pad_left        <= 2'd0;
        bmp_data_wr_en  <= 1'b0;
        bmp_data        <= 24'd0;
    end else begin
        if (bmp_data_wr_en && bmp_data_ready)
            bmp_data_wr_en <= 1'b0;

        if (state != ST_LOAD_DATA) begin
            bmp_len_cnt  <= 24'd0;
            bmp_byte_idx <= 2'd0;
            col_px       <= 16'd0;
            row_px       <= 16'd0;
            pad_left     <= 2'd0;
            bmp_data_wr_en <= 1'b0;
        end else if (sector_byte_can_consume) begin
            bmp_len_cnt <= bmp_len_cnt + 24'd1;
            if (bmp_data_valid) begin
                if (pad_left != 2'd0) begin
                    pad_left <= pad_left - 2'd1;
                    if (pad_left == 2'd1) begin
                        col_px <= 16'd0;
                        row_px <= row_px + 16'd1;
                    end
                end else begin
                    case (bmp_byte_idx)
                        2'd0: begin
                            bmp_data[7:0] <= sector_byte_q;
                            bmp_byte_idx  <= 2'd1;
                        end
                        2'd1: begin
                            bmp_data[15:8] <= sector_byte_q;
                            bmp_byte_idx   <= 2'd2;
                        end
                        2'd2: begin
                            bmp_data[23:16] <= sector_byte_q;
                            bmp_data_wr_en  <= 1'b1;
                            bmp_byte_idx    <= 2'd0;
                            if (column_last_q) begin
                                col_px <= 16'd0;
                                if (row_pad_bytes != 2'd0)
                                    pad_left <= row_pad_bytes;
                                else
                                    row_px <= row_px + 16'd1;
                            end else begin
                                col_px <= col_px + 16'd1;
                            end
                        end
                        default: bmp_byte_idx <= 2'd0;
                    endcase
                end
            end
        end
    end
end

always @(posedge clk or posedge rst) begin
    if (rst) begin
        abort_done        <= 1'b0;
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        data_start        <= 1'b0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
        load_failed         <= 1'b0;
    end else if (!sd_init_done) begin
        abort_done        <= 1'b0;
        state             <= ST_IDLE;
        state_code        <= 4'd0;
        data_start        <= 1'b0;
        sd_sec_read       <= 1'b0;
        sd_sec_read_addr  <= 32'd0;
        write_req         <= 1'b0;
        scan_done         <= 1'b0;
        scan_found_valid  <= 1'b0;
        scan_found_sector <= 32'd0;
        scan_found_total  <= 3'd0;
        scan_sector       <= 32'd0;
        load_sector_latched <= 32'd0;
        load_failed         <= 1'b0;
    end else begin
        data_start       <= 1'b0;
        scan_found_valid <= 1'b0;
        load_failed      <= 1'b0;

        if(abort_req)begin
            state<=ST_ABORT_WAIT;sd_sec_read<=0;write_req<=0;data_start<=0;load_failed<=0;
            if(abort_guard>=3)abort_done<=1;
        end else if(state==ST_ABORT_WAIT)begin
            state<=ST_IDLE;abort_done<=0;
        end else case (state)
            ST_IDLE: begin
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;

                if (scan_start) begin
                    scan_done        <= 1'b0;
                    scan_found_total <= 3'd0;
                    scan_sector      <= scan_start_sector;
                    sd_sec_read_addr <= scan_start_sector;
                    state            <= ST_SCAN;
                end else if (load_start) begin
                    load_sector_latched <= load_sector;
                    sd_sec_read_addr    <= load_sector;
                    state               <= ST_LOAD_HDR;
                end
            end

            ST_SCAN: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;

                    if (header_sector_complete && header_match) begin
                        scan_found_valid  <= 1'b1;
                        scan_found_sector <= scan_sector;
                        scan_found_total  <= scan_found_total + 3'd1;

                        if ((scan_found_total + 3'd1 >= scan_target_count) || (next_scan_sector_if_match > scan_max_sector)) begin
                            scan_done        <= 1'b1;
                            state            <= ST_IDLE;
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_match;
                            scan_sector      <= next_scan_sector_if_match;
                        end
                    end else begin
                        if (scan_sector >= scan_max_sector) begin
                            scan_done <= 1'b1;
                            state     <= ST_IDLE;
                        end else begin
                            sd_sec_read_addr <= next_scan_sector_if_miss;
                            scan_sector      <= next_scan_sector_if_miss;
                        end
                    end
                end
            end

            ST_LOAD_HDR: begin
                state_code  <= 4'd2;
                sd_sec_read <= 1'b1;

                if (sd_sec_read_end) begin
                    sd_sec_read <= 1'b0;
                    if (header_sector_complete && header_match) begin
                        write_req        <= 1'b1;
                        sd_sec_read_addr <= load_sector_latched;
                        state            <= ST_LOAD_WAIT;
                    end else begin
                        // 图头不对（读回来的不是合法 BMP）：原来是**静默**回 IDLE，
                        // 一个信号都不发，上层 load_busy 就永远清不掉 ⇒ 整机卡死。
                        // 现在报一个 load_failed 脉冲，上层据此跳下一组。
                        load_failed <= 1'b1;
                        state       <= ST_IDLE;
                    end
                end
            end

            ST_LOAD_WAIT: begin
                state_code <= 4'd3;
                if (write_req_ack) begin
                    write_req <= 1'b0;
                    state     <= ST_LOAD_DATA;
                    data_start <= 1'b1;
                end else if (ack_to) begin
                    // 等帧缓存写通道应答超时：报失败退出，不再永久挂住
                    write_req   <= 1'b0;
                    load_failed <= 1'b1;
                    state       <= ST_IDLE;
                end
            end

            ST_LOAD_DATA: begin
                state_code  <= 4'd4;
                if (need_sector_read)
                    sd_sec_read <= 1'b1;

                if (sd_sec_read_end)
                    sd_sec_read <= 1'b0;

                if (sector_last_byte_consume && byte_more_q)
                    sd_sec_read_addr <= sd_sec_read_addr + 32'd1;

                if (sd_sec_read_end && sector_loading && !data_sector_complete) begin
                    load_failed <= 1'b1;
                    state <= ST_IDLE;
                end else if (source_read_done) begin
                    sd_sec_read <= 1'b0;
                    state       <= ST_IDLE;
                end
            end

            default: begin
                state       <= ST_IDLE;
                state_code  <= 4'd1;
                sd_sec_read <= 1'b0;
                write_req   <= 1'b0;
            end
        endcase
    end
end

endmodule
