# TF 卡媒体准备

## 目录与文件名

TF 卡使用 FAT32 文件系统，将以下文件放在根目录：

- PHOTO1.BMP、PHOTO2.BMP、PHOTO3.BMP、PHOTO4.BMP。
- AUDIO1.WAV、AUDIO2.WAV、AUDIO3.WAV、AUDIO4.WAV。
- BGM.WAV。

同编号的图片与旁白配对，例如 PHOTO1.BMP 对应 AUDIO1.WAV。

## 图片格式

BMP 使用 24 位未压缩格式，宽度为 1–1024 像素，高度为 1–2048 像素。保留标准 BMP 文件头和行填充。

## 旁白格式

AUDIO1.WAV 至 AUDIO4.WAV 使用标准 PCM WAV：48 kHz、16 位、单声道。

## 背景音乐

BGM.WAV 使用专用播放路径，目录扫描要求文件总大小为 4,848,044 字节。替换背景音乐时须匹配播放器的采样格式、文件长度与循环边界；更改相关固件参数后需要重新验证播放效果。

## 内置资源

工程中的 MIF 文件用于存储字体、图形和其他 ROM 数据，属于构建输入。更换资源时须同时保持对应 ROM 的数据格式与地址范围。
