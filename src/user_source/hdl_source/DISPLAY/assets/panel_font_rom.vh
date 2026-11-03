//=============================================================================
//  panel_font_rom.v  —— 标题条 ROM（2026-10-23 第十版：单条完整句）
//
//  1024 x 16bit = 16384 bit -> 占 2 块 9K BRAM
//  地址    = 列号[9:0]
//  数据    = 该列的 16 行，bit[y] 对应屏幕上段第 y 行
//
//  内容由 58_gen_title.py 生成：一条 851 列的整句
//  「芯声屏步 手冲咖啡智能演示系统 + Xinsheng Screen Step: Hand Drip Coffee
//   Intelligent Demonstration System」，组尾 173 列留白，10bit 自然回绕。
//  RTL 侧既不需要字符索引，也不需要组长度表。
//
//  演进：
//    2026-10-17 第四版  512 列，整条预先栅格化，替代字模图集
//    2026-10-21         中文 13px -> 15.2px 墨宽（微软雅黑 Bold），修掉粘连看不清
//    2026-10-23 第八版  英文补全为整句，深度 512 -> 1024（单条 851 列正文）
//    2026-10-23 第九版  单条长标题 -> 4 组 x 512 列轮播，深度 1024 -> 2048
//    2026-10-23 第十版  撤销轮播，回到单条 1024 列（深度 2048 -> 1024，省 2 块 BRAM）
//
//  1bit/像素：小字做灰度反而更糊，见技能 §7。
//=============================================================================
`timescale 1ns / 1ps

module panel_font_rom (
    input  wire        clk,
    input  wire [9:0]  addr,
    output wire [15:0] dout
);

    EG_LOGIC_BRAM #(
        .DATA_WIDTH_A (16),
        .ADDR_WIDTH_A (10),
        .DATA_DEPTH_A (1024),
        .DATA_WIDTH_B (16),
        .ADDR_WIDTH_B (10),
        .DATA_DEPTH_B (1024),
        .MODE         ("SP"),
        .REGMODE_A    ("NOREG"),
        .IMPLEMENT    ("9K"),
        .DEBUGGABLE   ("NO"),
        .PACKABLE     ("NO"),
        .INIT_FILE    ("panel_font.mif"),
        .FILL_ALL     ("NONE")
    ) inst (
        .dia  (16'd0),
        .dib  (16'd0),
        .addra(addr),
        .addrb(10'd0),
        .cea  (1'b1),
        .ceb  (1'b0),
        .ocea (1'b0),
        .oceb (1'b0),
        .clka (clk),
        .clkb (1'b0),
        .wea  (1'b0),
        .web  (1'b0),
        .bea  (1'b0),
        .beb  (1'b0),
        .rsta (1'b0),
        .rstb (1'b0),
        .doa  (dout),
        .dob  ()
    );

endmodule
