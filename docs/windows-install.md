# 叠绘 / Compositor Windows 安装与使用

## 下载和安装

1. 打开 [Windows 编辑器下载页](https://github.com/Pengjingyu1992/Compositor-ZH/releases/tag/windows-v0.3.0-alpha.1)。
2. 目标系统：**Windows 10 22H2 / Windows 11，Intel/AMD x64**。下载 `Compositor-Windows-0.3.0-alpha.1-x64.exe`，运行安装向导。编辑器无需 Node.js 或 API Key；可选 AI 助手需配置自己的密钥。暂无 ARM64/32 位包。
3. 便携版下载同名 ZIP，**完整解压**，运行 `Compositor.exe`。保留 resources、DLL、语言资源和许可证。
4. 社区包未签名。核对来源和 SHA-256 后按系统提供的选项打开；无需关闭 Defender。
5. 右上角切换简体中文 / English，即时生效并保留到下次启动。

当前公开安装包仍为 `0.3.0-alpha.1`；共享源码为 `0.4.0-alpha.1` 并继续修复中。源码中的 GIF/EPS 和后续修复不代表上述下载包已更新。

真实 Win10/11 设备、中文输入法、高 DPI、多显示器、实际显卡与 Photoshop/Photopea 人工打开验收仍待完成。云端 Windows Server 的通过结果不等于这些项目已通过。

后续修复和优先事项见 [Linux / Windows 完善记录](linux-windows-review.md)。

## 界面布局

- 顶部保留 Windows 原生文件/编辑/显示/选择/图像/图层/滤镜/帮助菜单，紧凑文档栏放常用打开、新建、保存、撤销和缩放。
- 工具参数栏随左侧 17 个工具切换；左侧使用统一 SVG 图标。
- 右侧上方为图层：混合、不透明度、缩略图、可见性、蒙版与新增/删除操作；搜索按需展开。
- 右侧下方使用属性/调整/效果选项卡。原始数据和兼容性报告集中到“项目详情”，不占用常规编辑空间。
- 小画布也可放大适合窗口；100% 与用户缩放入口保留。

## 打开与编辑

- 打开项目时选择**整个 `.comp` 文件夹**；保留 manifest.json、images 和全部资源。Ctrl+O 选择项目文件夹，也可拖入一个完整文件夹。
- 开发分支读取格式版本 1–17，v17 的 16 位/ICC 原始 PNG 与方向处理已接入；编辑使用 8 位 sRGB 代理，保存保留未改动原图。高级元数据的编辑范围见功能对照表；旧发行包不会因此自动升级。
- 新建画布支持互换宽高。导入 PNG/JPEG，建立像素层/组/调整层、中文文字及矩形/椭圆/直线形状；文字和形状同时保存参数与像素，支持重新编辑。画笔改动文字/形状像素会移除其可编辑元数据，撤销可恢复。
- 左侧工具：移动、选框、套索、魔棒、裁剪、画笔、橡皮擦、修复、仿制、涂抹、渐变、油漆桶、形状、文字、取色、抓手、缩放。选中图层后绘画；目标选择“蒙版”可绘制白色显露、橡皮擦绘制黑色隐藏。Escape 取消当前笔画。
- 右侧编辑名称、可见性、不透明度、24 种混合、位置/大小/旋转/翻转、所属组和剪贴源；组移动带动全部后代。删除剪贴源会解除引用，组删除包含后代。Ctrl/Shift 多选，对齐/分布、编组、组树复制、合并/拼合共用事务；复制保留原始资源并生成新 UUID。
- 可添加/移除/反转/启停蒙版，切换链接状态。支持独立蒙版位置的渲染；蒙版解链后可编辑其位置、尺寸和旋转。
- 12 类调整：色相/饱和度、色阶、曲线、曝光、渐变映射、颗粒、反相、黑白、色彩平衡、高斯模糊、动感模糊、添加杂色。曲线点击添加点并可重置。6 类效果：描边、投影、颜色叠加、内阴影、外发光、内发光。
- Ctrl+Z 撤销、Ctrl+Shift+Z 重做；每个完整操作/笔画一个历史步骤。历史最多 80 步，按共享图像缓冲计入 256 MiB 预算。超预算时丢弃最旧历史。
- Ctrl+0 适合窗口、Ctrl+1 原始大小、Ctrl+滚轮缩放；抓手平移。搜索和折叠图层不会更改项目。

所有混合空间显式设为 sRGB；画质基准定标尚未完成。空间滤镜、描边及发光采用有界近似。高级 HSV 分色范围、未知属性和不能准确映射的剪贴关系会明确回退到保存的预览并禁止视觉编辑；仅允许改名及无损保存副本。没有预览时只显示图层/属性，不展示缺层的残缺合成图。

工具、选区、文字、滤镜、锁定与快捷键完整说明见 [Windows 编辑器工具补全](windows-full-editor.md)。

## 保存与恢复

- Ctrl+S 保存，Ctrl+Shift+S 另存为；首次保存选择 `.comp` 文件夹目标。源码中新建普通画布使用 `.comp` v11，动画使用 v16；打开旧项目后保留其格式版本，添加新格式功能时按需升级。
- 先写同卷临时完整包、逐文件刷新并回读验证，再提交。覆盖保存检查磁盘指纹；项目被其他程序修改时拒绝覆盖，需另存或重新打开。
- 覆盖时保留完整原项目备份 `.compositor-<UUID>.backup.comp`。Windows 的两次目录重命名不是整体原子操作；保存日志与备份支持中断恢复。启动后尝试恢复，无法自动处理时提示人工检查。确认新项目与备份可用后可以手动删除旧备份。
- 文件占用会有限退避重试，然后显示错误并保留项目/备份。OneDrive/同步盘可能占用或同步每个文件；首次建议保存到本机目录，完成后复制整个项目包。
- 每次编辑后延迟写恢复副本到 `%APPDATA%\Compositor-Windows\recovery`；每个文档保留最近两份，包含项目格式版本与修订号。恢复写入不会标记项目已保存，也不会覆盖源项目。支持格式 1–16 的可读取恢复包；可见但尚不支持编辑的属性需要保存的预览，并限制视觉编辑。没有因“版本不同”而直接丢弃。
- 文件菜单“恢复未保存项目”恢复最近副本，恢复后需另存。正常保存或明确放弃关闭后清理该文档的恢复副本。退出/打开其他项目有保存、放弃、取消提示。
- 未改动的图像/未知资源按原始字节保留，未知嵌套字段保留。视觉编辑删除过期 QuickLook 预览，不会把旧预览当作新图。
- 不自动上传项目文件或图像像素，无遥测/账号/自动更新。使用可选 AI 助手时，你输入的提示词和图层元数据会发送到你配置的接口；不会发送图像像素或整个项目。恢复副本含作品内容，仅存在本机；共享电脑请自行管理该目录。语言设置仍只存语言，不记录项目路径。

## PSD、PNG、EPS 与 GIF

- 源码新增 完整动画 GIF 导入/编辑/导出，以及像素 EPS 导入/导出；普通 EPS 需要单独安装 Ghostscript。旧安装包需等待包含本次改动的新发行版。支持范围和安装步骤见 [EPS/GIF 说明](eps-gif.md)。

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
Get-FileHash .\Compositor-Windows-0.3.0-alpha.1-x64.exe -Algorithm SHA256
```

与发行页 SHA256SUMS.txt 比较；ZIP 同样校验。

## 启动排查与反馈

本节对应 [Issue #5](https://github.com/Pengjingyu1992/Compositor-ZH/issues/5)。反馈时请注明使用的是公开安装包还是开发分支构建；`0.3.0-alpha.1` 的启动结果不能代替较新源码的验收。

### 进程存在，但窗口看不见

1. 先用任务栏、Alt+Tab、Win+Tab 查找编辑器窗口。多显示器用户可选中窗口后按 Win+Shift+左/右方向键，将窗口移回当前显示器。
2. 从原安装目录正常双击 `Compositor.exe` 或其快捷方式。开发分支已补充单实例唤醒：恢复最小化窗口、显示隐藏窗口，再请求焦点；仍使用原有窗口和未保存文档。Windows 的前台焦点策略可能只让任务栏闪烁，此时点击任务栏窗口即可。旧公开安装包未必含此修复。
3. 检查快捷方式的目标、起始目录和“运行方式”；诊断时使用“常规窗口”，不要使用 PowerShell 的 `Start-Process -WindowStyle Hidden`。此前 Issue 中的隐藏窗口由这种诊断启动方式引起，不能据此判定普通双击启动会崩溃。
4. 如果旧版本仍无法唤醒，先确认没有未保存作品，再通过任务管理器核对可执行文件位置，只结束这次启动的叠绘进程，随后正常启动。不要删除应用数据、恢复副本或整个项目目录，也不要批量结束其他 Electron 应用。

没有进程或进程立即退出时，先核对下载 SHA-256、ZIP 是否完整解压、系统架构和 Windows 安全中心记录。保留系统保护；请报告具体提示，不要以关闭 Defender 作为排查步骤。

### 获取可选的本地启动日志

应用没有默认开启的诊断日志上传。需要日志时，先通过应用正常退出已有实例，确保本次启动参数应用到新进程。在便携包的完整解压目录或安装目录打开 PowerShell，执行：

```powershell
$compositorExe = (Resolve-Path '.\Compositor.exe').Path
$compositorLog = Join-Path $env:TEMP ('compositor-startup-' + [guid]::NewGuid().ToString('N') + '.log')
Start-Process -FilePath $compositorExe -ArgumentList @('--enable-logging=file', ('--log-file="{0}"' -f $compositorLog))
```

只用合成画布复现；关闭应用后，可在同一个 PowerShell 中执行 `notepad $compositorLog` 查看。这个文件是本机 Chromium/Electron 诊断输出，并非完整操作记录；若应用在日志初始化前退出，可能没有文件。不要把“没有日志”当作启动成功。排查结束后由你决定是否删除该文件；正常双击启动不会自动沿用这些日志参数。

日志可能包含本机用户名、文件路径、网址、机器或驱动信息。公开反馈前请手动检查和删去这些信息；仅摘录与故障有关的错误及相邻少量上下文。不要附整个应用数据目录、恢复目录、个人 `.comp` 项目、原图、AI 提示词或 API 密钥。截图仅使用合成作品，并裁去桌面、账号和无关窗口。本流程不要求上传日志，也不增加遥测。

### 最短人工验收流程

使用本机普通目录与合成作品，逐项记录“通过 / 失败 / 未测试”，失败时写明停在哪一步：

1. 正常启动，确认可见的编辑器窗口；新建 256 × 192 px 透明画布，确认棋盘和实时预览。仅看到任务管理器进程不算窗口或画布通过。
2. 添加像素层，用画笔画一条线；撤销、重做，确认线条与历史一致。
3. 添加文字，使用实际中文输入法输入“叠绘测试”，检查候选框、确认输入和画布文字。自动化填入中文字符串不能代替输入法验收。
4. Ctrl+S 保存为新的 `synthetic-check.comp` 文件夹；确认未保存标记消失。关闭项目，再打开整个 `.comp` 文件夹，核对线条、中文与图层；只有完成重开核对才算保存往返通过。
5. 导出 PNG 和分层 PSD，用独立查看器检查 PNG 尺寸与内容；如有 Photoshop/Photopea，再人工打开 PSD 核对图层与外观。不能运行的外部应用验收填写“未测试”。
6. 单独记录实际 GPU、高 DPI、多显示器及最小化/隐藏后的再次启动结果；前五步通过不代表这些设备组合全部通过。

### 反馈模板

新增的 [Windows 启动与功能反馈表单](../.github/ISSUE_TEMPLATE/windows-feedback.yml) 合入默认分支后，可通过仓库的 New issue 入口使用；在此之前，请将下表复制到 Issue。无需提供用户名、机器名、个人路径或个人作品。

| 字段 | 请填写 |
| --- | --- |
| 应用版本与来源 | 版本号、发行标签或提交号、EXE 安装 / ZIP 便携 / Actions 构建 |
| Windows 与架构 | `winver` 中的版本和 OS build、x64；勿附包含账号信息的整屏截图 |
| GPU / 驱动 | 显卡型号与驱动版本；多显卡请注明本次使用哪块 |
| 显示环境 | 缩放百分比、显示器数量，是否在远程桌面中运行 |
| 包校验 | 下载文件名、SHA-256、与该包校验文件是否一致 |
| 启动阶段 | 无进程 / 只有进程 / 编辑器窗口可见 / 画布渲染成功 / 保存并重开成功 |
| 启动方式 | 正常双击 / 快捷方式 / 命令行；此前是否已有隐藏或最小化实例 |
| 复现 | 合成作品的最短步骤、预期结果、实际结果、出现频率 |
| 人工验收 | 绘画、中文 IME、撤销重做、保存重开、PNG、PSD 分别写通过/失败/未测试 |
| 可选证据 | 已检查和删去隐私的少量日志、仅含合成作品的窗口截图 |

## 开发构建（Windows）

```powershell
git clone https://github.com/Pengjingyu1992/Compositor-ZH.git
cd Compositor-ZH\windows
npm ci
npm run build
npm start
npm run package:win
```

推荐 Node.js 24（项目至少需要 22.12）和 Git。输出在 windows/release。云端工作流做源码/本地化审查、类型检查、编辑/保存故障注入、独立 PSD 读取、软件 GPU 打包 GUI 检查与许可证/包审查。

## English summary

Install the x64 EXE or fully extract the ZIP from the [Windows editor download page](https://github.com/Pengjingyu1992/Compositor-ZH/releases/tag/windows-v0.3.0-alpha.1). The editor needs no Node.js or API key; the optional AI assistant uses your own key. Verify SHA-256; packages are unsigned. Target: Windows 10 22H2 / Windows 11 x64; hardware, IME, high-DPI and real Photoshop acceptance remain pending.

For startup problems, use the feedback table above or the [Windows feedback form](../.github/ISSUE_TEMPLATE/windows-feedback.yml) once it reaches the default branch. Report the app version/build source, Windows build, architecture, GPU/driver, display scaling, package checksum and last verified stage: process only, visible editor, rendered canvas, or save/reopen. The development branch now explicitly shows hidden windows on a second launch. Exit existing instances normally before enabling the optional local log described above; avoid hidden-window launches. Review and redact any log excerpts before sharing, and use synthetic projects only. Real IME, hardware and external PSD checks must be recorded separately from automated tests.

Use 17 tools: selections, crop/resize, Chinese text, editable shapes, gradients/bucket, painting/masks, clone/healing/smear, navigation and eyedropper. Multi-select, align/distribute, group/duplicate/merge, 21 filters, adjustments/effects, clipboard, undo/redo, Save/Save As, recovery and PSD/PNG conversion are available. Unknown data is retained. Text/shapes save parameters with pixels; painting rasterizes them. Locks are session-only. Unsupported compositions remain read-only with explicit saved-preview fallback. All 24 blends use sRGB, with image-quality calibration pending; spatial filters/effects use bounded approximations.

Overwrite saves stage and validate a complete package, reject external changes, retain a complete backup, and use a durable journal for interruption recovery. Two directory renames are not one atomic operation. Recovery copies never mark the project saved. PSD layers preserve core structure/masks; text/shapes rasterize and adjustment/effect projects require explicit flattened PSD export. No telemetry; optional AI requests send your prompt and layer metadata to the endpoint you configure, without image pixels or project files.

Thank you to [Robbie Tilton, Compositor](https://github.com/robbietilton/Compositor) and [Terry Jia, Pentrado](https://github.com/jtydhr88/pentrado). See [Windows notices](../windows/THIRD_PARTY_NOTICES.md).
