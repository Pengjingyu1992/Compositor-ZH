# PSD 导入 / PSD import

macOS 1.4.8（40.28）支持 RGB、8 位或 16 位／通道的 PSD/PSB，在内存与尺寸限制内读取图层、组、透明度和蒙版。支持原始数据、PackBits、ZIP、带预测的 ZIP 四种通道压缩，以及 Photoshop 的 `Lr16` 图层表。文字、路径、调整与效果仍遵守现有转换说明，不代表所有 Photoshop 特性都可无损编辑。

导入 16 位文件时，先显示转换确认：像素与像素蒙版会转换为叠绘当前使用的 **8 位 RGB**，保留支持的图层结构；这不是原生 16 位编辑。取消不修改画布或撤销历史。没有图层记录、仅含合成图的 16 位文件也需要确认。源 PSD/PSB 不会被覆盖，建议将编辑结果保存为新的 `.comp` 项目。

CMYK、Lab、索引色以及 32 位浮点 PSD 暂未支持。请在 Photoshop 中转换一个 RGB、8 位或 16 位副本再导入，保留原稿。PSD 嵌入色彩配置的完整转换与原生高位深处理另行安排。

读取器对文件段长度、通道长度、解压后尺寸与校验和进行检查。ZIP 逐行解码，只保留目标区域；异常或过大的输入会报错，不分配整个隐藏源图层的解压缓冲区。

## 检查 / Checks

`scripts/check-psd-import-clt.zsh [local-file.psd]` 生成独立的合成样例，检查 8/16 位、四种压缩、PSD/PSB、主图层表/全局图层表、裁切、透明度、蒙版、损坏输入、确认/取消、撤销及无图层导入。可选的私人样例仅在本机读取，检查输出保存在被忽略的 `build/psd-import-checks/`，不应提交原稿或其输出。

2026-10-18 本机验证：372 项定向检查通过；用户报告的 971 × 1619、16 位 RGB 样例成功导入四个图层并导出 PNG。独立逐通道解码与应用输出的预乘颜色最大差异为 1/255，合成图与 PSD 保存的合成图最大差异为 1/255；原文件内容校验一致。安装版 40.28 已实际验证中文转换提示、四个图层与画布显示、错误弹窗的单一确认按钮。中英文词条与占位符检查通过。完整 Xcode 测试套件未运行。

## English

macOS 1.4.8 (40.28) imports 8-bit and 16-bit RGB PSD/PSB files within the app's size and memory limits. It reads regular and `Lr16` layer tables and supports raw, PackBits, ZIP and ZIP with prediction. Layers, groups, opacity and masks are retained where supported; text, paths, adjustments and effects remain subject to the existing conversion report.

Importing 16-bit pixels requires confirmation before conversion to the app's **8-bit RGB working format**, including pixel masks. This does not add native 16-bit editing. Canceling leaves the canvas and undo history unchanged, including for layerless files. The original PSD/PSB is never overwritten. Save edits to a new `.comp` project.

CMYK, Lab, indexed color and 32-bit floating-point PSD import remain unsupported. Convert a copy to 8-bit or 16-bit RGB in Photoshop and keep the original. Complete embedded-profile conversion and native high-depth editing remain separate work.

ZIP decoding validates declared output size and checksums while retaining a row buffer and the requested crop. The CLT regression script above uses independently generated fixtures; optional private inputs and rendered outputs remain local.
