// FAT32 root-directory scanner for the fixed 8.3 media names.
// It reads the BPB at sector 0, then scans every sector in the root
// directory's first cluster. The media entries used by this project fit
// within that cluster.
module fat32_directory_scanner (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,

    output reg         sd_read_req,
    output reg [31:0]  sd_read_sector,
    input  wire [7:0]  sd_read_data,
    input  wire        sd_read_data_valid,
    input  wire        sd_read_end,

    output reg         busy,
    output reg         done,
    output reg         error,
    output reg [31:0]  fat_start_sector,
    output reg [31:0]  first_data_sector,
    output reg [7:0]   sectors_per_cluster,

    output reg [31:0]  photo1_cluster,
    output reg [31:0]  photo2_cluster,
    output reg [31:0]  photo3_cluster,
    output reg [31:0]  photo4_cluster,
    output reg [31:0]  audio1_cluster,
    output reg [31:0]  audio2_cluster,
    output reg [31:0]  audio3_cluster,
    output reg [31:0]  audio4_cluster,
    output reg [31:0]  photo1_size,
    output reg [31:0]  photo2_size,
    output reg [31:0]  photo3_size,
    output reg [31:0]  photo4_size,
    output reg [31:0]  audio1_size,
    output reg [31:0]  audio2_size,
    output reg [31:0]  audio3_size,
    output reg [31:0]  audio4_size,
    output reg [27:0]  bgm_cluster
);
    localparam [31:0] BGM_WAV_SIZE_BYTES = 32'd4_848_044;

    localparam ST_IDLE      = 4'd0;
    localparam ST_BOOT_READ = 4'd1;
    localparam ST_BOOT_SELECT= 4'd2;
    localparam ST_BOOT_CALC = 4'd3;
    localparam ST_ROOT_READ = 4'd4;
    localparam ST_ROOT_GAP  = 4'd5;
    localparam ST_FINISH    = 4'd6;
    localparam ST_ROOT_ADDR = 4'd8;
    localparam ST_BOOT_CHECK = 4'd9;
    localparam ST_BOOT_BASE = 4'd7;   // 2026-10-23：ST_BOOT_CALC 拆成两级

    reg [3:0]  state;
    reg bpb_ok_q, mbr_ok_q, geometry_ok_q;
    reg [8:0]  byte_count;
    reg [15:0] bytes_per_sector;
    reg [15:0] reserved_sector_count;
    reg [7:0]  fat_count;
    reg [31:0] fat_size_sectors;
    reg [31:0] root_cluster;
    reg [31:0] partition_start_sector;
    reg [7:0]  partition_type;
    reg [7:0]  boot_signature_0;
    reg [7:0]  boot_signature_1;
    reg [31:0] root_start_sector;
    reg [31:0] data_base_sector;   // 数据区起点（分区起点 + 保留区 + FAT 区）
    reg [7:0]  root_sector_index;

    reg [87:0] entry_name;
    reg [7:0]  entry_attr;
    reg [31:0] entry_cluster;
    reg [31:0] entry_size;
    reg        entry_active;
    reg        entry_commit_pending;
    reg        dir_end;          // saw the "no more entries" marker (first byte 0x00)
    reg        mbr_stage;        // 1 while reading the FIRST boot sector (the MBR):
                                 // its partition table must not be overwritten by
                                 // the second read (the partition's own BPB)
    // ------------------------------------------------------------------
    // 布局判定（2026-09-18 新增）
    //   sector 0 有两种完全合法的布局：
    //     (a) superfloppy —— 第 0 扇区本身就是 FAT32 引导扇区，分区起点 = 0
    //     (b) MBR         —— 第 0 扇区是分区表，分区起点 = 分区表项1 的起始 LBA
    //   判据必须来自 BPB 字段自身的有效性（多条件组合），不能只看某一个
    //   字节、也不能只看 OEM 名称：superfloppy 卡上偏移 450 / 454-457 落在
    //   引导代码区，内容是随机字节（实测到过 "ey t" 这样的字符串），
    //   若被误当作分区类型 / 起始 LBA，地址会飞到卡外。
    //
    //   ⚠️ 采集顺序上的固有约束：读第 0 扇区的那一拍，判定还没做
    //      （要整扇区读完才能判），所以偏移 450/454-457 总是先采进来。
    //      是否可信，由 ST_BOOT_SELECT 的判定结果决定 —— 判为 superfloppy
    //      时在那里强制把 partition_start_sector 清零，随机字节因此不会
    //      流入后续地址计算。bpb_checked 保证判定只做一次。
    // ------------------------------------------------------------------
    reg        bpb_checked;      // 判定已做过（ST_BOOT_SELECT 只判一次）
    reg [8:0]  found_mask;
    wire [3:0] file_kind;
    reg [3:0] file_kind_q;
    always @(posedge clk) file_kind_q <= file_kind;

    function [31:0] cluster_to_sector;
        input [31:0] cluster;
        input [7:0]  cluster_sectors;
        begin
            case (cluster_sectors)
                8'd1:   cluster_to_sector = cluster - 32'd2;
                8'd2:   cluster_to_sector = (cluster - 32'd2) << 1;
                8'd4:   cluster_to_sector = (cluster - 32'd2) << 2;
                8'd8:   cluster_to_sector = (cluster - 32'd2) << 3;
                8'd16:  cluster_to_sector = (cluster - 32'd2) << 4;
                8'd32:  cluster_to_sector = (cluster - 32'd2) << 5;
                8'd64:  cluster_to_sector = (cluster - 32'd2) << 6;
                8'd128: cluster_to_sector = (cluster - 32'd2) << 7;
                default:cluster_to_sector = 32'd0;
            endcase
        end
    endfunction

    function [31:0] fat_region_sectors;
        input [7:0]  count;
        input [31:0] size;
        begin
            case (count)
                8'd1:   fat_region_sectors = size;
                8'd2:   fat_region_sectors = size << 1;
                8'd4:   fat_region_sectors = size << 2;
                default:fat_region_sectors = 32'd0;
            endcase
        end
    endfunction

    // ------------------------------------------------------------------
    // 「这个扇区看起来像不像一个 FAT32 引导扇区（BPB）？」
    //   六条判据全部取自 BPB 字段自身的有效性与签名，逐条独立：
    //     ① 偏移 11-12  每扇区字节数 == 512
    //     ② 偏移 13     每簇扇区数   != 0
    //     ③ 偏移 16     FAT 份数     != 0
    //     ④ 偏移 36-39  每 FAT 扇区数 != 0
    //     ⑤ 偏移 510-511 == 55 AA
    //     ⑥ 偏移 44-47  根目录簇号    >= 2
    //   六条全中才认作 BPB。MBR 不可能同时满足这六条（它的 11-12 是分区表
    //   里的随机字节，且 13/16/36-39 落在分区项/保留区）。
    // ------------------------------------------------------------------
    function bpb_is_valid;
        input [15:0] f_bps;
        input [7:0]  f_spc;
        input [7:0]  f_nfat;
        input [31:0] f_fatsz;
        input [31:0] f_rootclus;
        input [7:0]  f_sig0;
        input [7:0]  f_sig1;
        begin
            bpb_is_valid = (f_bps == 16'd512)     &&
                           (f_spc != 8'd0)        &&
                           (f_nfat != 8'd0)       &&
                           (f_fatsz != 32'd0)     &&
                           (f_rootclus >= 32'd2)  &&
                           (f_sig0 == 8'h55) && (f_sig1 == 8'haa);
        end
    endfunction

    fat32_name_match u_fat32_name_match (
        .entry_name(entry_name),
        .file_kind (file_kind)
    );

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state                 <= ST_IDLE;
            sd_read_req           <= 1'b0;
            sd_read_sector        <= 32'd0;
            busy                  <= 1'b0;
            done                  <= 1'b0;
            error                 <= 1'b0;
            byte_count            <= 9'd0;
            bytes_per_sector      <= 16'd0;
            reserved_sector_count <= 16'd0;
            fat_count             <= 8'd0;
            fat_size_sectors      <= 32'd0;
            root_cluster          <= 32'd0;
            partition_start_sector<= 32'd0;
            partition_type       <= 8'd0;
            boot_signature_0      <= 8'd0;
            boot_signature_1      <= 8'd0;
            fat_start_sector      <= 32'd0;
            first_data_sector     <= 32'd0;
            root_start_sector     <= 32'd0;
            data_base_sector      <= 32'd0;
            sectors_per_cluster   <= 8'd0;
            root_sector_index     <= 8'd0;
            entry_name            <= 88'd0;
            entry_attr            <= 8'd0;
            entry_cluster         <= 32'd0;
            entry_size            <= 32'd0;
            entry_active          <= 1'b0;
            entry_commit_pending  <= 1'b0;
            dir_end               <= 1'b0;
            mbr_stage             <= 1'b0;
            bpb_checked           <= 1'b0;
            found_mask            <= 9'd0;
            photo1_cluster        <= 32'd0;
            photo2_cluster        <= 32'd0;
            photo3_cluster        <= 32'd0;
            photo4_cluster        <= 32'd0;
            audio1_cluster        <= 32'd0;
            audio2_cluster        <= 32'd0;
            audio3_cluster        <= 32'd0;
            audio4_cluster        <= 32'd0;
            bgm_cluster           <= 28'd0;
            photo1_size           <= 32'd0;
            photo2_size           <= 32'd0;
            photo3_size           <= 32'd0;
            photo4_size           <= 32'd0;
            audio1_size           <= 32'd0;
            audio2_size           <= 32'd0;
            audio3_size           <= 32'd0;
            audio4_size           <= 32'd0;
        end else begin
            case (state)
                ST_IDLE: begin
                    done  <= 1'b0;
                    error <= 1'b0;
                    busy  <= 1'b0;
                    if (start) begin
                        busy                  <= 1'b1;
                        byte_count            <= 9'd0;
                        bytes_per_sector      <= 16'd0;
                        reserved_sector_count <= 16'd0;
                        fat_count             <= 8'd0;
                        fat_size_sectors      <= 32'd0;
                        root_cluster          <= 32'd0;
                        partition_start_sector<= 32'd0;
                        partition_type       <= 8'd0;
                        boot_signature_0      <= 8'd0;
                        boot_signature_1      <= 8'd0;
                        fat_start_sector      <= 32'd0;
                        first_data_sector     <= 32'd0;
                        root_start_sector     <= 32'd0;
                        data_base_sector      <= 32'd0;
                        sectors_per_cluster   <= 8'd0;
                        root_sector_index     <= 8'd0;
                        dir_end               <= 1'b0;
                        mbr_stage             <= 1'b1;
                        bpb_checked           <= 1'b0;
                        found_mask            <= 9'd0;
                        photo1_cluster        <= 32'd0;
                        photo2_cluster        <= 32'd0;
                        photo3_cluster        <= 32'd0;
                        photo4_cluster        <= 32'd0;
                        audio1_cluster        <= 32'd0;
                        audio2_cluster        <= 32'd0;
                        audio3_cluster        <= 32'd0;
                        audio4_cluster        <= 32'd0;
                        bgm_cluster           <= 28'd0;
                        photo1_size           <= 32'd0;
                        photo2_size           <= 32'd0;
                        photo3_size           <= 32'd0;
                        photo4_size           <= 32'd0;
                        audio1_size           <= 32'd0;
                        audio2_size           <= 32'd0;
                        audio3_size           <= 32'd0;
                        audio4_size           <= 32'd0;
                        sd_read_sector        <= 32'd0;
                        sd_read_req           <= 1'b1;
                        state                 <= ST_BOOT_READ;
                    end
                end

                ST_BOOT_READ: begin
                    if (sd_read_data_valid) begin
                        case (byte_count)
                            9'd11: bytes_per_sector[7:0]           <= sd_read_data;
                            9'd12: bytes_per_sector[15:8]          <= sd_read_data;
                            9'd13: sectors_per_cluster             <= sd_read_data;
                            9'd14: reserved_sector_count[7:0]      <= sd_read_data;
                            9'd15: reserved_sector_count[15:8]     <= sd_read_data;
                            9'd16: fat_count                        <= sd_read_data;
                            9'd36: fat_size_sectors[7:0]           <= sd_read_data;
                            9'd37: fat_size_sectors[15:8]          <= sd_read_data;
                            9'd38: fat_size_sectors[23:16]         <= sd_read_data;
                            9'd39: fat_size_sectors[31:24]         <= sd_read_data;
                            9'd44: root_cluster[7:0]               <= sd_read_data;
                            9'd45: root_cluster[15:8]              <= sd_read_data;
                            9'd46: root_cluster[23:16]             <= sd_read_data;
                            9'd47: root_cluster[31:24]             <= sd_read_data;
                            // 偏移 450 / 454-457 只在读**第 0 扇区**那一趟采集
                            // （mbr_stage=1）。第 0 扇区既可能是 MBR（真分区表，
                            // 这两处是有效信息），也可能是 BPB（引导代码区，
                            // 这两处是随机字节）。
                            // ⚠️ 读的时候还没法判断是哪种 —— 判定要到本状态读完、
                            //    进 ST_BOOT_SELECT 才能做。所以这里**照采**，
                            //    采到的值是否可信，由 ST_BOOT_SELECT 的判定结果
                            //    决定：判为 superfloppy 时会在那里强制清零，
                            //    保证随机字节不会流入地址计算。
                            9'd450: if (mbr_stage) partition_type                <= sd_read_data;
                            9'd454: if (mbr_stage) partition_start_sector[7:0]    <= sd_read_data;
                            9'd455: if (mbr_stage) partition_start_sector[15:8]   <= sd_read_data;
                            9'd456: if (mbr_stage) partition_start_sector[23:16]  <= sd_read_data;
                            9'd457: if (mbr_stage) partition_start_sector[31:24]  <= sd_read_data;
                            9'd510: boot_signature_0                 <= sd_read_data;
                            9'd511: boot_signature_1                 <= sd_read_data;
                            default: ;
                        endcase
                        byte_count <= byte_count + 9'd1;
                    end
                    if (sd_read_end) begin
                        sd_read_req <= 1'b0;
                        mbr_stage   <= 1'b0;   // only the FIRST boot sector is the MBR
                        state       <= ST_BOOT_SELECT;
                    end
                end

                ST_BOOT_SELECT: begin
                    bpb_ok_q <= bpb_is_valid(bytes_per_sector,sectors_per_cluster,
                        fat_count,fat_size_sectors,root_cluster,boot_signature_0,boot_signature_1);
                    geometry_ok_q <= bytes_per_sector == 16'd512 && sectors_per_cluster != 0 &&
                        fat_count != 0 && fat_size_sectors != 0 && root_cluster >= 2;
                    mbr_ok_q <= boot_signature_0 == 8'h55 && boot_signature_1 == 8'haa &&
                        (partition_type == 8'h0b || partition_type == 8'h0c) && partition_start_sector != 0;
                    state <= ST_BOOT_CHECK;
                end
                ST_BOOT_CHECK: begin
                    // ----------------------------------------------------------
                    // 判第 0 扇区的布局（只判一次，bpb_checked 做闸门）
                    //
                    //   superfloppy：第 0 扇区六条 BPB 判据全中
                    //                ⇒ 它自己就是引导扇区，分区起点 = 0
                    //                且**忽略**偏移 450/454-457（引导代码区垃圾）
                    //
                    //   MBR：      第 0 扇区不满足全部判据，且 55AA 在、
                    //              分区表项1 的类型与起始 LBA 都合理
                    //              ⇒ 跳到该 LBA 读真正的 BPB
                    //
                    //   两者都不成立 ⇒ 交给 ST_BOOT_CALC 报错（error=1）
                    // ----------------------------------------------------------
                    if (!bpb_checked) begin
                        if (bpb_ok_q) begin
                            // (a) 第 0 扇区本身就是 FAT32 引导扇区
                            bpb_checked           <= 1'b1;
                            partition_start_sector<= 32'd0;   // 分区起点就是 0
                            partition_type        <= 8'd0;
                            state                 <= ST_BOOT_CALC;
                        end else if (mbr_ok_q) begin
                            // (b) 合法的 MBR：跳去分区自己的引导扇区
                            bpb_checked           <= 1'b1;
                            bytes_per_sector      <= 16'd0;
                            reserved_sector_count <= 16'd0;
                            fat_count             <= 8'd0;
                            fat_size_sectors      <= 32'd0;
                            root_cluster          <= 32'd0;
                            sectors_per_cluster   <= 8'd0;
                            byte_count            <= 9'd0;
                            sd_read_sector        <= partition_start_sector;
                            sd_read_req           <= 1'b1;
                            state                 <= ST_BOOT_READ;
                        end else begin
                            // 都不是 ⇒ 直接交给 CALC 报错
                            bpb_checked <= 1'b1;
                            state       <= ST_BOOT_CALC;
                        end
                    end else begin
                        // 第二次进来 = 刚读完 MBR 指向的那个 BPB，直接算地址。
                        // 此时 partition_start_sector 就是分区起点（采集时已
                        // 确认为 MBR，偏移 454-457 的值可信）。
                        state <= ST_BOOT_CALC;
                    end
                end

                ST_BOOT_CALC: begin
                    if (!geometry_ok_q) begin
                        busy  <= 1'b0;
                        error <= 1'b1;
                        state <= ST_IDLE;
                    end else begin
                        // partition_start_sector = 分区在整个卡上的起始扇区。
                        //   superfloppy 卡（无 MBR）⇒ 0，已在 ST_BOOT_SELECT 里
                        //   强制置 0（第 0 扇区偏移 454-457 的垃圾值不会被采进来）。
                        //   有 MBR 的卡 ⇒ 来自分区表项1 的起始 LBA（典型 32 或 2048）。
                        // **后面所有地址都必须加上它**，否则会跑到卡开头找文件。
                        //
                        // Reuse root_start_sector for the cluster offset until
                        // ST_ROOT_ADDR. Split subtract/shift and base additions.
                        fat_start_sector <= partition_start_sector + reserved_sector_count;
                        root_start_sector <= cluster_to_sector(root_cluster,sectors_per_cluster);
                        state             <= ST_BOOT_BASE;
                    end
                end

                ST_BOOT_BASE: begin
                    data_base_sector <= fat_start_sector +
                                        fat_region_sectors(fat_count,fat_size_sectors);
                    state <= ST_ROOT_ADDR;
                end
                ST_ROOT_ADDR: begin
                    first_data_sector <= data_base_sector;
                    root_start_sector <= data_base_sector + root_start_sector;
                    root_sector_index <= 8'd0;
                    byte_count        <= 9'd0;
                    sd_read_sector    <= data_base_sector + root_start_sector;
                    sd_read_req       <= 1'b1;
                    state             <= ST_ROOT_READ;
                end

                ST_ROOT_READ: begin
                    // Commit a completed 32-byte directory entry before
                    // collecting the first byte of the next entry.
                    if (entry_commit_pending && (sd_read_data_valid || sd_read_end)) begin
                        case (file_kind_q)
                            4'd1: begin photo1_cluster <= entry_cluster; photo1_size <= entry_size; found_mask[0] <= 1'b1; end
                            4'd2: begin photo2_cluster <= entry_cluster; photo2_size <= entry_size; found_mask[1] <= 1'b1; end
                            4'd3: begin photo3_cluster <= entry_cluster; photo3_size <= entry_size; found_mask[2] <= 1'b1; end
                            4'd4: begin photo4_cluster <= entry_cluster; photo4_size <= entry_size; found_mask[3] <= 1'b1; end
                            4'd5: begin audio1_cluster <= entry_cluster; audio1_size <= entry_size; found_mask[4] <= 1'b1; end
                            4'd6: begin audio2_cluster <= entry_cluster; audio2_size <= entry_size; found_mask[5] <= 1'b1; end
                            4'd7: begin audio3_cluster <= entry_cluster; audio3_size <= entry_size; found_mask[6] <= 1'b1; end
                            4'd8: begin audio4_cluster <= entry_cluster; audio4_size <= entry_size; found_mask[7] <= 1'b1; end
                            4'd9: begin
                                if ((entry_size == BGM_WAV_SIZE_BYTES) &&
                                    (entry_cluster[27:0] >= 28'd2)) begin
                                    bgm_cluster <= entry_cluster[27:0];
                                    found_mask[8] <= 1'b1;
                                end
                            end
                            default: ;
                        endcase
                        entry_commit_pending <= 1'b0;
                    end

                    if (sd_read_data_valid) begin
                        case (byte_count[4:0])
                            5'd0: begin
                                entry_name    <= {80'd0, sd_read_data};
                                entry_attr    <= 8'd0;
                                entry_cluster <= 32'd0;
                                entry_size    <= 32'd0;
                                entry_active  <= (sd_read_data != 8'h00) && (sd_read_data != 8'he5);
                                // FAT32: an entry whose first byte is 0x00 marks
                                // the end of the directory - nothing after it
                                // can be a file, so stop scanning there.
                                dir_end       <= (sd_read_data == 8'h00);
                            end
                            5'd1, 5'd2, 5'd3, 5'd4, 5'd5, 5'd6, 5'd7, 5'd8, 5'd9, 5'd10:
                                entry_name <= {entry_name[79:0], sd_read_data};
                            5'd11: entry_attr <= sd_read_data;
                            5'd20: entry_cluster[23:16] <= sd_read_data;
                            5'd21: entry_cluster[31:24] <= sd_read_data;
                            5'd26: entry_cluster[7:0]   <= sd_read_data;
                            5'd27: entry_cluster[15:8]  <= sd_read_data;
                            5'd28: entry_size[7:0]      <= sd_read_data;
                            5'd29: entry_size[15:8]     <= sd_read_data;
                            5'd30: entry_size[23:16]    <= sd_read_data;
                            5'd31: begin
                                entry_size[31:24]        <= sd_read_data;
                                entry_commit_pending     <= entry_active && (entry_attr != 8'h0f);
                            end
                            default: ;
                        endcase
                        byte_count <= byte_count + 9'd1;
                    end

                    if (sd_read_end) begin
                        sd_read_req <= 1'b0;
                        // finish early when the directory's end marker was seen:
                        // the remaining sectors of the root cluster are padding
                        if (dir_end || (root_sector_index + 8'd1 >= sectors_per_cluster))
                            state <= ST_FINISH;
                        else begin
                            root_sector_index <= root_sector_index + 8'd1;
                            state             <= ST_ROOT_GAP;
                        end
                    end
                end

                ST_ROOT_GAP: begin
                    byte_count     <= 9'd0;
                    sd_read_sector <= root_start_sector + root_sector_index;
                    sd_read_req    <= 1'b1;
                    state          <= ST_ROOT_READ;
                end

                ST_FINISH: begin
                    // The scan itself always succeeds: whatever was found is
                    // reported through the per-file cluster values, where 0
                    // means "not present on the card".  Missing files are NOT
                    // a scanner error - the main controller skips such groups.
                    busy  <= 1'b0;
                    done  <= 1'b1;
                    error <= 1'b0;
                    state <= ST_IDLE;
                end

                default: begin
                    state       <= ST_IDLE;
                    sd_read_req <= 1'b0;
                    busy        <= 1'b0;
                end
            endcase
        end
    end
endmodule

// Convert the four discovered photo clusters into absolute data-sector
// addresses over three clock stages per photo. Keeping subtraction, scaling,
// and base addition in separate stages avoids a long FAT-to-player path.
// Scanner outputs are held stable after done until the next scan starts.
module fat32_photo_sector_mapper (
    input  wire        clk,
    input  wire        rst,
    input  wire        start,
    input  wire [31:0] first_data_sector,
    input  wire [7:0]  sectors_per_cluster,
    input  wire [31:0] photo1_cluster,
    input  wire [31:0] photo2_cluster,
    input  wire [31:0] photo3_cluster,
    input  wire [31:0] photo4_cluster,
    output reg         busy,
    output reg         done,
    output reg  [31:0] photo1_sector,
    output reg  [31:0] photo2_sector,
    output reg  [31:0] photo3_sector,
    output reg  [31:0] photo4_sector
);
    localparam [1:0] ST_IDLE  = 2'd0;
    localparam [1:0] ST_SUB   = 2'd1;
    localparam [1:0] ST_SCALE = 2'd2;
    localparam [1:0] ST_BASE  = 2'd3;

    reg [1:0]  state;
    reg [1:0]  photo_index;
    reg [31:0] cluster_minus_two;
    reg [31:0] sector_offset;
    wire [31:0] selected_cluster;

    assign selected_cluster =
        (photo_index == 2'd0) ? photo1_cluster :
        (photo_index == 2'd1) ? photo2_cluster :
        (photo_index == 2'd2) ? photo3_cluster : photo4_cluster;

    function [31:0] scale_cluster_offset;
        input [31:0] cluster_offset;
        input [7:0]  cluster_sectors;
        begin
            case (cluster_sectors)
                8'd1:   scale_cluster_offset = cluster_offset;
                8'd2:   scale_cluster_offset = cluster_offset << 1;
                8'd4:   scale_cluster_offset = cluster_offset << 2;
                8'd8:   scale_cluster_offset = cluster_offset << 3;
                8'd16:  scale_cluster_offset = cluster_offset << 4;
                8'd32:  scale_cluster_offset = cluster_offset << 5;
                8'd64:  scale_cluster_offset = cluster_offset << 6;
                8'd128: scale_cluster_offset = cluster_offset << 7;
                default:scale_cluster_offset = 32'd0;
            endcase
        end
    endfunction

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            state             <= ST_IDLE;
            photo_index       <= 2'd0;
            cluster_minus_two <= 32'd0;
            sector_offset     <= 32'd0;
            busy              <= 1'b0;
            done              <= 1'b0;
            photo1_sector     <= 32'd0;
            photo2_sector     <= 32'd0;
            photo3_sector     <= 32'd0;
            photo4_sector     <= 32'd0;
        end else begin
            done <= 1'b0;
            if (start) begin
                state       <= ST_SUB;
                photo_index <= 2'd0;
                busy        <= 1'b1;
            end else begin
                case (state)
                    ST_IDLE: begin
                        busy <= 1'b0;
                    end

                    ST_SUB: begin
                        cluster_minus_two <= selected_cluster - 32'd2;
                        state             <= ST_SCALE;
                    end

                    ST_SCALE: begin
                        sector_offset <= scale_cluster_offset(cluster_minus_two,
                                                               sectors_per_cluster);
                        state <= ST_BASE;
                    end

                    ST_BASE: begin
                        case (photo_index)
                            2'd0: photo1_sector <= first_data_sector + sector_offset;
                            2'd1: photo2_sector <= first_data_sector + sector_offset;
                            2'd2: photo3_sector <= first_data_sector + sector_offset;
                            2'd3: photo4_sector <= first_data_sector + sector_offset;
                        endcase

                        if (photo_index == 2'd3) begin
                            state <= ST_IDLE;
                            busy  <= 1'b0;
                            done  <= 1'b1;
                        end else begin
                            photo_index <= photo_index + 1'b1;
                            state       <= ST_SUB;
                        end
                    end

                    default: begin
                        state <= ST_IDLE;
                        busy  <= 1'b0;
                    end
                endcase
            end
        end
    end
endmodule
