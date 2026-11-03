# 咖啡文化多媒体交互展示系统

基于 Anlogic EG4S20BG256 FPGA 的咖啡文化展示系统，通过 HDMI 屏幕和 HUB75 RGB 点阵呈现图像、文字与动画，并结合旁白和背景音乐实现交互展示。

## 功能

- 从 TF 卡读取 BMP 图片和 WAV 音频。
- 支持图片自动播放、手动切换和快速轮播。
- 图片与对应旁白联动，背景音乐独立播放。
- 提供图片转场、亮度和对比度调节。
- 显示字幕、Logo 和背景音乐频谱。
- 支持四格选图和 HUB75 点阵显示。
- 包含开场动画与音乐。

## 开发环境与硬件

| 项目 | 配置 |
| --- | --- |
| FPGA | Anlogic EG4S20BG256 |
| 开发工具 | Tang Dynasty（TD）6.2.168116 |
| 顶层模块 | top |
| 主显示 | HDMI |
| 媒体存储 | FAT32 TF 卡 |
| 点阵显示 | HUB75 64×64 RGB 点阵 |

引脚分配见 src/user_source/constraints_source/pin.adc，时序约束见同目录 timing.sdc。连接外设时请结合开发板手册核对接口和供电。

## 目录结构

- src/td_project/：TD 工程、IP 配置及显示资源。
- src/user_source/：HDL 源码、约束和模块资源。
- docs/MEDIA.md：TF 卡文件命名和媒体格式。
- NOTICE.md：第三方组件声明。

## 打开与构建

1. 安装 TD 和相应器件支持。
2. 打开 src/td_project/HDMI1.4b_Transmitter_v1.0.al。
3. 若工程记录的项目目录与实际位置不一致，在 TD 中更新工程路径，并核对源文件列表。
4. 保持 td_project 与 user_source 同级；工程工作目录使用 td_project，确保 include 和 MIF 相对路径能正确解析。
5. 依次执行综合、布局布线、时序检查和 bit 文件生成。
6. 按开发板手册下载配置文件，并检查显示、按键、点阵和音频功能。

MIF 文件保存了字体、图形等 ROM 数据，是构建输入，请保留。仓库不包含 TD 安装程序或预编译 bit 文件。

## 媒体准备

将 PHOTO1.BMP 至 PHOTO4.BMP、AUDIO1.WAV 至 AUDIO4.WAV 和 BGM.WAV 放入 FAT32 卡根目录。具体格式与 BGM 长度要求见 [媒体说明](docs/MEDIA.md)。

外部照片、旁白和背景音乐需使用者自行准备，并遵守素材的使用许可。

## 已知限制

播放过程中可能偶发音频失真。

## 第三方组件

厂商 IP 和其他第三方内容的声明见 [NOTICE.md](NOTICE.md)。
