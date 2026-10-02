# 叠绘 / Compositor Windows 安装与使用

## 下载和安装

1. 打开 [Windows 编辑预览版发行页](https://github.com/Pengjingyu1992/Compositor-ZH/releases/tag/windows-v0.2.0-alpha.2)。`releases/latest` 保留给 macOS。
2. 目标系统：**Windows 10 22H2 / Windows 11，Intel/AMD x64**。下载 `Compositor-Windows-0.2.0-alpha.2-x64.exe`，运行安装向导。无需 Node.js、Xcode 或 API Key；暂无 ARM64/32 位包。
3. 便携版下载同名 ZIP，**完整解压**，运行 `Compositor.exe`。保留 resources、DLL、语言资源和许可证。
4. 社区包未签名。核对来源和 SHA-256 后按系统提供的选项打开；无需关闭 Defender。
5. 右上角切换简体中文 / English，即时生效并保留到下次启动。

真实 Win10/11 设备、中文输入法、高 DPI、多显示器、实际显卡与 Photoshop/Photopea 人工打开验收仍待完成。云端 Windows Server 的通过结果不等于这些项目已通过。本版保留为预发布，不替换 macOS 安装包或更新入口。

## 界面布局

- 顶部保留 Windows 原生文件/编辑/显示/图层/帮助菜单，紧凑文档栏放常用打开、新建、保存、撤销和缩放。
- 工具参数栏随移动/画笔/橡皮擦/抓手切换；左侧使用统一 SVG 图标。
- 右侧上方为图层：混合、不透明度、缩略图、可见性、蒙版与新增/删除操作；搜索按需展开。
- 右侧下方使用属性/调整/效果选项卡。原始数据和兼容性报告集中到“项目详情”，不占用常规编辑空间。
- 小画布也可放大适合窗口；100% 与用户缩放入口保留。

## 打开与编辑

- 将 macOS 保存的**整个 `.comp` 文件夹**复制到 Windows；保留 manifest.json、images 和全部资源。Ctrl+O 选择项目文件夹，也可拖入一个完整文件夹。
- 新建画布支持互换宽高。导入 PNG/JPEG，建立像素层/组/调整层；现有文字和形状使用保存的像素。画笔改动文字/形状像素会移除其可编辑元数据，撤销可恢复。
- 左侧工具：移动（V）、画笔（B）、橡皮擦（E）、抓手（H）。选中图层后绘画；目标选择“蒙版”可绘制白色显露、橡皮擦绘制黑色隐藏。Escape 取消当前笔画。
- 右侧编辑名称、可见性、不透明度、24 种混合、位置/大小/旋转/翻转、所属组和剪贴源；组移动带动全部后代。删除剪贴源会解除引用，组删除包含后代。复制像素层保留原始资源并生成新 UUID。
- 可添加/移除/反转/启停蒙版，切换链接状态。支持独立蒙版位置的渲染；本版没有独立蒙版变换控件。
- 12 类调整：色相/饱和度、色阶、曲线、曝光、渐变映射、颗粒、反相、黑白、色彩平衡、高斯模糊、动感模糊、添加杂色。曲线点击添加点并可重置。6 类效果：描边、投影、颜色叠加、内阴影、外发光、内发光。
- Ctrl+Z 撤销、Ctrl+Shift+Z 重做；每个完整操作/笔画一个历史步骤。历史最多 80 步，按共享图像缓冲计入 256 MiB 预算。超预算时丢弃最旧历史。
- Ctrl+0 适合窗口、Ctrl+1 原始大小、Ctrl+滚轮缩放；抓手平移。搜索和折叠图层不会更改项目。

Windows 渲染仍是**候选实现**：所有混合空间显式设为 sRGB；尚未完成 macOS 黄金图定标。空间滤镜、描边及发光采用有界近似，不能据功能名称宣称逐像素一致。高级 HSV 分色范围、未知属性和不能准确映射的剪贴关系会明确回退到保存的预览并禁止视觉编辑；仅允许改名及无损保存副本。没有预览时只显示图层/属性，不展示缺层的残缺合成图。

## 保存与恢复

- Ctrl+S 保存，Ctrl+Shift+S 另存为；首次保存选择 `.comp` 文件夹目标。保存沿用 macOS 的 v11 已定义字段，没有改变 macOS 文件格式或代码。
- 先写同卷临时完整包、逐文件刷新并回读验证，再提交。覆盖保存检查磁盘指纹；项目被其他程序修改时拒绝覆盖，需另存或重新打开。
- 覆盖时保留完整原项目备份 `.compositor-<UUID>.backup.comp`。Windows 的两次目录重命名不是整体原子操作；保存日志与备份支持中断恢复。启动后尝试恢复，无法自动处理时提示人工检查。确认新项目与备份可用后可以手动删除旧备份。
- 文件占用会有限退避重试，然后显示错误并保留项目/备份。OneDrive/同步盘可能占用或同步每个文件；首次建议保存到本机目录，完成后复制整个项目包。
- 每次编辑后延迟写恢复副本到 `%APPDATA%\Compositor-Windows\recovery`；每个文档保留最近两份，包含项目格式版本与修订号。恢复写入不会标记项目已保存，也不会覆盖源项目。支持格式 1–11 的可读取恢复包；没有因“版本不同”而直接丢弃。
- 文件菜单“恢复未保存项目”恢复最近副本，恢复后需另存。正常保存或明确放弃关闭后清理该文档的恢复副本。退出/打开其他项目有保存、放弃、取消提示。
- 未改动的图像/未知资源按原始字节保留，未知嵌套字段保留。视觉编辑删除过期 QuickLook 预览，不会把旧预览当作新图；Mac 打开并保存后会重新生成预览。
- 不上传项目、无遥测/账号/自动更新。恢复副本含作品内容，仅存在本机；共享电脑请自行管理该目录。语言设置仍只存语言，不记录项目路径。

## PSD 与 PNG

- 导入预算内的 **8 位 RGB PSD**（不支持 PSB）。基础像素层、组、顺序、位移、不透明度、混合和栅格蒙版进行分层转换；文字使用保存的像素。复杂效果、矢量/智能对象等无法准确转换时，先提示，用户可取消或选择“导入保存的合成图”（一个像素层）。
- PSD 导出说明明确显示文字/形状转换为像素。分层导出保留像素层、组、顺序、位移、不透明度、混合和蒙版；位置/旋转会烘焙到有边界的像素区域。剪贴要求连续同级层；无法表示时拒绝分层导出。
- 当前含调整层或启用效果的项目需选择扁平 PSD，保留新渲染合成图但不保留可编辑层。PSD 转换不是 `.comp` 的无损替代。
- PNG 导出当前完整画布。只有完成的新渲染可导出，不导出过期 QuickLook 图。
- 云端用独立 `psd-tools` 读取器校验 PSD 层数/顺序/偏移/透明度/混合/蒙版/像素；真实 Photoshop/Photopea 打开仍待人工完成。

## 预算与兼容性反馈

读取限额：manifest 4 MiB、单个资源 64 MiB、累计编码资源 256 MiB、画布边长 30,000 px、图层 10,000 个、源图像/蒙版各 1 亿像素。新像素资源和 PSD 单层不超过 1600 万像素；PSD 导入累计解码估算 512 MiB，层数不超过 1000。

合成上限另受 **768 MiB 保守工作预算**及 GPU 纹理上限限制。估算包含工作线程滤镜、合成目标、全尺寸读回、CPU/GPU 位置副本及蒙版；超过时不分配大工作面，明确回退。大画布可能只能查看，不能按此说明推断已有分块性能。需要 WebGL2 与 EXT_color_buffer_float；上下文丢失中断渲染并回退。Pentrado 固定 0.1.1，其接口早于作者仓库新的 quad/presentCanvas。

“复制兼容性报告”仅复制聚合尺寸/数量/版本/预算/兼容性状态，不含项目名、路径、图层名/ID 或原始元数据，不自动发送。报告标明黄金图与真实设备验收尚未完成。

## 校验下载

```powershell
Get-FileHash .\Compositor-Windows-0.2.0-alpha.2-x64.exe -Algorithm SHA256
```

与发行页 SHA256SUMS.txt 比较；ZIP 同样校验。

## 开发构建（Windows）

```powershell
git clone https://github.com/Pengjingyu1992/Compositor-ZH.git
cd Compositor-ZH\windows
npm ci
npm run build
npm start
npm run package:win
```

需要 Node.js 24 和 Git。输出在 windows/release。云端工作流做源码/本地化审查、类型检查、编辑/保存故障注入、独立 PSD 读取、软件 GPU 打包 GUI 检查与许可证/包审查。按要求开发者本机不运行测试、应用或构建。

Windows 使用 windows-v* 标签、预发布、make_latest=false。下载审核候选产物、创建绑定确切 SHA 的草稿，再用 Windows upload reviewed draft assets 上传已通过云端产物；发布后验证 `/releases/latest` 仍为 macOS。原生 macOS 代码、安装包和设置不参与本批改动。

## English summary

Install the x64 EXE or fully extract the ZIP from the [Windows editor prerelease](https://github.com/Pengjingyu1992/Compositor-ZH/releases/tag/windows-v0.2.0-alpha.2). No Node.js or API key is required. Verify SHA-256; packages are unsigned. Target: Windows 10 22H2 / Windows 11 x64; hardware, IME, high-DPI and real Photoshop acceptance remain pending.

Edit layers, paint pixels/masks, adjust appearance and effects, undo/redo, Save/Save As, restore local snapshots, and convert PSD/PNG. Unknown data is retained. Text/shapes use saved pixels and are rasterized by painting. Unsupported compositions remain read-only with explicit saved-preview fallback. All 24 blends are candidates, with macOS golden-image calibration pending; spatial filters/effects use bounded approximations.

Overwrite saves stage and validate a complete package, reject external changes, retain a complete backup, and use a durable journal for interruption recovery. Two directory renames are not one atomic operation. Recovery copies never mark the project saved. PSD layers preserve core structure/masks; text/shapes rasterize and adjustment/effect projects require explicit flattened PSD export. No telemetry or project upload. Windows settings, releases and binaries are independent of macOS.

Thank you to [Robbie Tilton, Compositor](https://github.com/robbietilton/Compositor) and [Terry Jia, Pentrado](https://github.com/jtydhr88/pentrado). See [Windows notices](../windows/THIRD_PARTY_NOTICES.md).
