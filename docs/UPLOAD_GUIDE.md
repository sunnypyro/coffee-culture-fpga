# 用 GitHub 网页逐步上传

## 创建仓库

1. 登录 github.com。
2. 点击右上角 +，选择 New repository。
3. Repository name 建议 coffee-culture-fpga；Description 填 FPGA 咖啡文化多媒体交互展示系统。
4. NOTICE.md 中第三方许可未确认时，可先用 Private 保存；正式公开前完成许可确认和自有代码许可证选择。
5. 勾选 Add a README file；.gitignore 和 License 先选 None。
6. 点击 Create repository。

## 分批上传

官方网页限制是每批最多 100 文件、单文件最多 25 MiB：
https://docs.github.com/en/repositories/working-with-files/managing-files/adding-a-file-to-a-repository

本地源码有 116 文件，请分批，保留目录层次：

1. 在仓库首页选择 Add file → Upload files，上传本地 README.md、NOTICE.md、.gitignore、SOURCE_MANIFEST.sha256 和 docs 文件夹。它们会替换初始化 README。填写提交说明 Add project documentation，提交到 main。
2. 用 Add file → Create new file 创建 src/.gitkeep，填写占位说明或保持空白，提交。
3. 打开网页 src 目录，选择 Add file → Upload files，拖入本地 src/td_project 文件夹（17 文件），填写 Add TD project 并提交。
4. 留在网页 src 目录，同样拖入本地 src/user_source 文件夹（99 文件），填写 Add HDL sources 并提交。
5. 不要把文件全部摊平到根目录；td_project 与 user_source 必须同级。网页 .gitignore 不会替你过滤已选中的上传文件。
6. 对照本地目录，检查 src/td_project/HDMI1.4b_Transmitter_v1.0.al 存在。

## 正式公开

先完成 NOTICE.md 的第三方许可确认，并为有权授权的自有代码选定 LICENSE，按要求保留第三方条款。再将仓库设为 Public，从未登录窗口确认仓库可访问，复制仓库链接用于比赛提交。

上传本地 E:/coffee 中整理的内容即可；不需要上传原工程的 Git 历史。只选择实际文件和子目录，不要拖名为 coffee 的外层文件夹导致多套一层路径。
