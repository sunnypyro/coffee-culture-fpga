# 咖啡文化多媒体交互展示系统

基于 Anlogic EG4S20BG256 FPGA 的多媒体展示工程，包括 HDMI 图像/音频播放、TF 卡 BMP/WAV 读取、字幕与 Logo、图片转场、BGM 频谱、HUB75 点阵和四格选图。

## 版本与验证边界

本包导出自 2026-11-03 冻结的主工程 v15，来源提交 063b275b48636d7d15556c0c9d2cd791ec812375。上传副本仅适配工程根路径，并去除生成文件注释中的本机路径；HDL 功能、引脚、时序约束和 MIF 数据保持来源版本。

来源主工程已有 8 项定向 RTL 回归、原生综合/布局布线/bitgen及最终端点检查通过的记录；最终 Routed setup +0.108 ns、hold +0.022 ns，TNS 均为 0。未重跑全长开场动画仿真。本上传副本未重新编译或上板。

已知问题：用户报告开场完整，偶发声音扭曲仍未解决。主 v15 新 bit 未独立上板确认；内部时序结果不能替代整机板测及全部外部接口电气验证。

## 软件与工程入口

- 工具：Tang Dynasty（TD），来源工程记录版本 6.2.168116。
- 器件：EG4S20BG256；顶层模块：top。
- 工程入口：src/td_project/HDMI1.4b_Transmitter_v1.0.al。
- HDL 与约束：src/user_source。
- 所需 MIF 图形、字体和 ROM 数据已保留。

本机可从 E:/coffee/src/td_project 打开工程。移动目录后，请在 TD 中核对工程根路径；.al 的 Project Path 目前指向本上传副本。保持 td_project 与 user_source 同级，从 td_project 使用工程，以便 include 和 MIF 相对路径正确解析。

安装兼容的 TD 和器件支持后，打开 .al，核对器件和文件列表，依次执行综合、布局布线、最终时序检查和 bit 生成。生成物进入 *_Runs。下载到开发板前须按板卡手册检查器件、供电和引脚。仓库没有附 TD 安装包或预编译 bit。

## 媒体与硬件

目标工程包含 HDMI、TF 卡与 HUB75 64×64 RGB 点阵接口；具体引脚以 src/user_source/constraints_source/pin.adc 为准，时序约束见同目录 timing.sdc。不要仅凭接口名称改接线。

FAT32 卡根目录使用 PHOTO1.BMP 至 PHOTO4.BMP、AUDIO1.WAV 至 AUDIO4.WAV，以及 BGM.WAV。媒体规格见 docs/MEDIA.md。外部 TF 卡音乐、旁白和照片未随包提供，需要自行准备合法素材。

## 文件和许可

- src：116 个来源工程必要输入。
- docs：媒体说明、整理检查记录及网页上传说明。
- SOURCE_MANIFEST.sha256：上传副本源码的 SHA-256 清单。
- .gitignore：编译输出和本地缓存排除规则。
- NOTICE.md：第三方 IP、代码和素材许可待确认事项。

本工程包含厂商加密 HDMI/SDRAM IP 及厂商生成代码。原始版权声明保留。自有代码主许可证尚待作者选择；第三方文件不能自动由主许可证授权。公开发布前应完成 NOTICE.md 中的许可确认。
