// Gives one physical SD-card sector port to directory scan, image loading,
// and audio streaming. A granted sector transfer always completes before the
// next requester is selected. Directory scanning has startup priority; once
// audio requests a slot, it gets the next one after the active sector ends.
module sd_sector_arbiter (
    input  wire        clk,
    input  wire        rst,

    input  wire        dir_req,
    input  wire [31:0] dir_sector,
    output wire [7:0]  dir_data,
    output wire        dir_valid,
    output wire        dir_end,

    output wire        img_inflight,
    input  wire        img_req,
    input  wire [31:0] img_sector,
    output wire [7:0]  img_data,
    output wire        img_valid,
    output wire        img_end,

    input  wire        aud_req,
    input  wire [31:0] aud_sector,
    output wire [7:0]  aud_data,
    output wire        aud_valid,
    output wire        aud_end,

    output reg         phy_req,
    output reg [31:0]  phy_sector,
    input  wire [7:0]  phy_data,
    input  wire        phy_valid,
    input  wire        phy_end
);
    localparam OWN_NONE = 2'd0;
    localparam OWN_DIR  = 2'd1;
    localparam OWN_IMG  = 2'd2;
    localparam OWN_AUD  = 2'd3;

    reg [1:0] owner;
    reg       release_pending;
    assign img_inflight=(owner==OWN_IMG);

    // ------------------------------------------------------------------
    // 2026-09-15 新增：给三个消费方各打一拍再送出去
    //
    // 原因：布局布线后的时序报告里，"SPI 收到的字节 -> 消费方寄存器"这条路径是
    // **真实超时**的（SWNS −1.406 ns，扇出 34、布线占 68%、逻辑级数 9），
    // 因为三个消费方（目录扫描、读图、读歌）离 SPI 很远，长走线直接落进它们的组合逻辑。
    // 把"数据 / 有效 / 结束"三个信号**一起**打一拍之后，长走线的终点变成寄存器，
    // 而寄存器就摆在消费方旁边 ⇒ 这条长路径被切成两段短路径。
    // 三个信号同步延后一拍，握手语义完全不变（消费方都是在 valid/end 同拍判定的）。
    // ------------------------------------------------------------------
    reg [7:0] dir_data_r, img_data_r, aud_data_r;
    reg       dir_valid_r, img_valid_r, aud_valid_r;
    reg       dir_end_r,   img_end_r,   aud_end_r;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            dir_data_r  <= 8'd0;  img_data_r  <= 8'd0;  aud_data_r  <= 8'd0;
            dir_valid_r <= 1'b0;  img_valid_r <= 1'b0;  aud_valid_r <= 1'b0;
            dir_end_r   <= 1'b0;  img_end_r   <= 1'b0;  aud_end_r   <= 1'b0;
        end else begin
            dir_data_r  <= phy_data;  img_data_r  <= phy_data;  aud_data_r  <= phy_data;
            dir_valid_r <= phy_valid && (owner == OWN_DIR);
            img_valid_r <= phy_valid && (owner == OWN_IMG);
            aud_valid_r <= phy_valid && (owner == OWN_AUD);
            dir_end_r   <= phy_end   && (owner == OWN_DIR);
            img_end_r   <= phy_end   && (owner == OWN_IMG);
            aud_end_r   <= phy_end   && (owner == OWN_AUD);
        end
    end

    assign dir_data  = dir_data_r;
    assign img_data  = img_data_r;
    assign aud_data  = aud_data_r;
    assign dir_valid = dir_valid_r;
    assign img_valid = img_valid_r;
    assign aud_valid = aud_valid_r;
    assign dir_end   = dir_end_r;
    assign img_end   = img_end_r;
    assign aud_end   = aud_end_r;

    always @(posedge clk or posedge rst) begin
        if (rst) begin
            owner           <= OWN_NONE;
            release_pending <= 1'b0;
            phy_req         <= 1'b0;
            phy_sector      <= 32'd0;
        end else if (release_pending) begin
            owner           <= OWN_NONE;
            release_pending <= 1'b0;
            phy_req         <= 1'b0;
        end else if (owner == OWN_NONE) begin
            if (dir_req) begin
                owner      <= OWN_DIR;
                phy_sector <= dir_sector;
                phy_req    <= 1'b1;
            end else if (aud_req) begin
                owner      <= OWN_AUD;
                phy_sector <= aud_sector;
                phy_req    <= 1'b1;
            end else if (img_req) begin
                owner      <= OWN_IMG;
                phy_sector <= img_sector;
                phy_req    <= 1'b1;
            end
        end else if (phy_end) begin
            phy_req         <= 1'b0;
            release_pending <= 1'b1;
        end
    end
endmodule
