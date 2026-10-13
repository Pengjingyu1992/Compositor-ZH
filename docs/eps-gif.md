# EPS 与 GIF / EPS and GIF

macOS 1.4.8（40.24，`v1.4.8-zh.4`）包含以下支持。Windows 源码也已加入这些功能，但已发布的 Windows 0.3.0 安装包不包含这些入口。两版分别构建。动画项目使用 `.comp` v16；普通项目和 EPS 不改变原有保存版本。

The following support is included in macOS 1.4.8 (40.24, `v1.4.8-zh.4`). Windows source also includes these additions, but the published Windows 0.3.0 package does not. The editions build separately. Animation projects use `.comp` v16; ordinary projects and EPS keep their existing save version.

| 格式 / Format | 打开、导入 / Open and import | 导出 / Export |
| --- | --- | --- |
| GIF | 完整导入图像帧、透明区域、局部更新、处置方式 0/1/2/3、时长与循环次数。每帧成为独立图层文件夹。 / Imports image frames, transparency, partial updates, disposal 0/1/2/3, timing and repeats into frame folders. | 导出全部帧，保留时长、循环与二值透明度，每帧最多 256 色；macOS 也可用背景色填充透明区域。 / Exports all frames with timing, repeats and binary transparency, up to 256 colors per frame; macOS also offers a matte. |
| EPS / EPSF / EPSI | 转为一个 RGB 像素图层，不保留可编辑文字、路径、图层或专色。普通 EPS 以 144 DPI 渲染；叠绘原样导出的像素 EPS 直接读回原尺寸和 DPI。 / One RGB raster layer; editable text, paths, layers and spot colors are not preserved. General EPS renders at 144 DPI; unmodified Compositor raster EPS reads back at its original dimensions and DPI. | 标准 EPSF 3.0 / PostScript Level 2，包含扁平 RGB 图像；透明区域填充为背景色，按文档 DPI 写入物理尺寸。此导出不是矢量或分层导出。 / Standard EPSF 3.0 / PostScript Level 2 with a flattened RGB image and physical dimensions derived from document DPI. Transparency uses a matte. This is not vector or layered export. |

## 使用入口 / Commands

- **macOS**：文件 → 导入图像；也可从访达“打开方式”或拖入 EPS/GIF。文件 → 导出为… → 选择 GIF 或 EPS。 / File → Import Image, Finder Open With, or drop an EPS/GIF. File → Export As… → GIF or EPS.
- **Windows**：文件 → 导入图像，可在没有打开项目时创建对应尺寸的画布。文件 → 导出 GIF… / 导出 EPS…。 / File → Import image, including when no document is open; File → Export GIF… / Export EPS….
- 需要保留可编辑图层时，继续保存 `.comp`。EPS/GIF 导出不会把项目标记为已保存，也不会覆盖原项目。 / Keep a `.comp` project for editable layers. EPS/GIF export does not mark project edits saved or overwrite the project.

## 动画编辑 / Animation editing

1. 导入 GIF 后使用底部动画时间轴；普通画布可点“创建动画”。可选择、新建、复制、删除、前后移动帧，修改每帧毫秒时长，并播放/暂停。Windows 也可用空格播放/暂停。 / Use the bottom timeline after importing GIF, or choose Create Animation on an ordinary canvas. Select, add, duplicate, delete, reorder and retime frames, then play/pause. Windows also supports Space to play/pause.
2. 选中帧后，用现有画笔、文字、形状、选区、变换、蒙版和滤镜等工具编辑该帧的图层。帧文件夹外的图层是共享背景/叠加层，依照原堆叠顺序出现在每帧中。切帧/播放不产生撤销条目；修改内容、时长和顺序可撤销。 / Existing tools edit the selected frame's layers. Layers outside frame folders are shared backgrounds/overlays in their existing stacking order. Seeking/playback does not create history; content, timing and ordering changes do.
3. 重复次数 `−1` 为播放一次、`0` 为无限循环、正整数为首次播放后的额外重复次数。时长按 GIF 的 10 毫秒精度保存；原文件的零/缺失时长规范为 100 毫秒。 / Repeats: −1 once, 0 forever, positive values count extra iterations. GIF timing has 10 ms precision; zero/absent delays normalize to 100 ms.
4. 保存 `.comp` v16 可继续编辑全部帧及图层，恢复副本也保留动画。PNG/JPEG/EPS 等静态格式导出当前帧；PSD 保留帧文件夹和当前可见性，时长需留在 `.comp` 或 GIF。旧叠绘不支持 v16，不能用旧版打开动画项目。 / Save `.comp` v16 for editable frames/layers and recovery. Still formats export the current frame. PSD retains folders/current visibility; timing stays in `.comp` or GIF. Older app versions cannot open v16 animation projects.
5. macOS 导入已有画布时追加帧，原画布层成为共享内容；Windows GIF 作为新的动画文档打开，替换前询问是否保存当前项目。 / macOS appends imported frames to the existing canvas, retaining original layers as shared content. Windows opens GIF as a new animation document, prompting to save the current project first.

## 普通 EPS 的附加组件 / General EPS interpreter

普通 EPS 是 PostScript 程序，需要单独安装当前受支持的 **Ghostscript 10** 发行版。叠绘自身导出且未经其他软件改写的像素 EPS、所有 EPS 导出、GIF 读写均不需要此组件。应用不自动下载、捆绑或链接 Ghostscript。

General EPS contains a PostScript program and needs a separately installed, maintained Ghostscript 10 release. Unmodified Compositor raster EPS, all EPS export, and GIF import/export need no interpreter. The application does not download, bundle or link Ghostscript.

### macOS

1. 已使用 Homebrew 的用户可运行 `brew install ghostscript`；或按 [Ghostscript 官方说明](https://ghostscript.readthedocs.io/en/latest/Install.html) 安装当前版本。 / Existing Homebrew users can run `brew install ghostscript`, or follow the official installation instructions.
2. 叠绘 → 设置… → **EPS 导入 → 选择 Ghostscript 目录…**。Homebrew 的 Apple Silicon 默认前缀是 `/opt/homebrew`；另一个常见前缀是 `/usr/local`。仅支持上述两个安装前缀。请选择包含 `bin/gs`、依赖库和字体的前缀，而不是只选择 `gs` 文件。 / Settings → EPS Import → Choose Ghostscript Folder…; only these two installation prefixes are supported; select the prefix containing `bin/gs`, its libraries and fonts.
3. 该选择保存在本机的只读安全书签中，可以“取消目录授权”。应用保持沙盒；执行例外仅针对上述前缀中的 Ghostscript 程序及其自身安装目录，其他依赖通过用户选择的目录授权访问。 / Access is stored as a local read-only security bookmark and can be forgotten. The app stays sandboxed, with execution exceptions limited to Ghostscript's executable and own installation directories at these prefixes. Other dependencies require the selected folder grant.

### Windows 10 / 11 x64

1. 从 [Ghostscript 官方下载页](https://ghostscript.com/releases/gsdnld.html) 安装当前 Windows x64 发行版。 / Install the current Windows x64 release from the official download page.
2. 默认安装在 `Program Files\gs\gs版本号\bin\gswin64c.exe` 时，叠绘会自动发现，并优先选择较新的版本。自定义安装位置可设置 `COMPOSITOR_GHOSTSCRIPT` 环境变量为该可执行文件的完整路径，然后重新启动叠绘。 / Standard Program Files installations are detected automatically, newest first. For a custom installation, set `COMPOSITOR_GHOSTSCRIPT` to the absolute executable path and restart the app.

请按 Ghostscript 自身的许可证使用该独立组件。官方文档：[使用与安全选项](https://ghostscript.readthedocs.io/en/latest/Use.html)。 / The separately installed interpreter is governed by its own license; see its usage and security documentation.

## 限额与失败处理 / Limits and failures

- GIF、EPS：最多 **1600 万像素**，单边最多 **30,000 像素**。GIF 输入/输出最多 64 MiB；最多 500 帧，所有帧合计最多 6400 万像素。Windows 帧 PNG 缓冲另限 192 MiB。EPS 输入/输出最多 128 MiB。加入已有文档时还受文档累计预算约束。 / Up to 16 million pixels and 30,000 pixels per side; GIF input/output up to 64 MiB, up to 500 frames and 64 million total frame pixels. Windows encoded frame buffers also cap at 192 MiB. EPS input/output up to 128 MiB. The document's cumulative budget also applies.
- 普通 EPS 必须有有效的 `BoundingBox` / `HiResBoundingBox`，支持文本 EPS 和 DOS 二进制包装。外部解释器使用 `SAFER`、固定像素尺寸、独立临时目录、限定输入输出路径和 **30 秒超时**，不通过 shell 执行。尺寸和缓冲区参数并非整个解释器的进程内存硬上限。 / General EPS needs a valid bounding box; text EPS and DOS wrappers are accepted. The interpreter uses SAFER, fixed geometry, a private temporary directory, explicit file permissions and a 30-second timeout, without a shell. Geometry and buffer settings are not a hard process-memory limit.
- Windows 的 GIF 解码、调色板编码和 EPS 像素编解码在可终止的工作线程执行；结果提交前检查文档及修订号。 / Windows GIF decoding, palette encoding and raster EPS codecs run in terminable workers, with document and revision checks before commit.
- GIF 的罕见文本渲染块暂不支持，会明确报错；不会静默丢帧。 / Rare GIF plain-text rendering blocks are unsupported and produce an error rather than silently losing frames.
- 损坏文件、尺寸超限、缺少解释器或渲染失败均显示错误；不会把 TIFF 预览冒充 EPS 正文。普通 EPS 所需外部字体/资源缺失时可能失败或发生字体替代。 / Damage, excessive size, a missing interpreter or render failure produces an error. An embedded TIFF preview is never substituted for the EPS program. Missing fonts/resources can cause failure or font substitution.

## 验证记录 / Verification status

2026-10-12：macOS **1.4.8（40.24）** 的应用与 CLI 编译完成，本机安装后的严格签名检查通过；Windows **0.4.0-alpha.1** 的类型检查与生产构建完成。1446 个 macOS 本地化候选键无缺失、未译或未解析表达式；配置、JavaScript 语法、改动差异及源码/应用常见隐私模式检查通过。尚未上传或发布这批改动，也未生成 Windows 安装包。

2026-10-12: macOS **1.4.8 (40.24)** app/CLI compilation and installed strict-signature review passed; Windows **0.4.0-alpha.1** type checking and production build passed. All 1446 macOS localization candidates resolved, with no missing/untranslated keys. Configuration, JavaScript syntax, diff formatting and common privacy-pattern checks of source/app files passed. These changes are not yet uploaded or released; a Windows installer has not been produced.

按用户要求不运行本地功能测试。交付时分别记录编译、语法/本地化/配置检查结果；Windows 真机、普通 EPS 的沙盒解释器调用、第三方 EPS 阅读器及动画 GIF 真实样例仍需运行验收。静态检查和编译不能代替这些验证。

Local functional tests are not run at the user's request. Compilation and syntax/localization/configuration review are reported separately. Real Windows behavior, sandboxed interpreter invocation, third-party EPS readers and real animated GIF samples still require runtime acceptance; static checks and compilation do not establish those results.
