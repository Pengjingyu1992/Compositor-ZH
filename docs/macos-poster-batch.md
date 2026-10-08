# macOS 海报与照片编辑批次

## 使用入口

| 功能 | 入口与行为 |
|---|---|
| 可编辑填充 | 图层 → 新建填充图层。纯色、线性/径向多色渐变、棋盘格/条纹/圆点图案；双击图层或菜单再次编辑。支持蒙版与变换。像素绘制/滤镜/重采样后栅格化。 |
| 图层样式 | 图层效果中新增渐变叠加、图案叠加、斜面和浮雕。各自显示、复制、取消和撤销，预览与导出共用 CPU 渲染。浮雕首版为内斜面高光/阴影。 |
| 手动修边 | 图层 → 修整图层边缘。显示/隐藏/引导修边笔刷、主体检测、黑白/棋盘/蒙版背景、羽化/边缘位移/对比度、净化边缘颜色。默认创建副本并隐藏原层；净化颜色始终保留原层。 |
| 彩色半调 | 滤镜 → 彩色半调。CMYK 四组网角、圆形/方形/线形网点、尺寸与强度，经典印刷/报纸/波普预设。输出为 RGB 印刷模拟，不是 CMYK 文档。现有选区、图层蒙版和撤销仍生效。 |
| 调色 | 图像 → 可选颜色 / 通道混合器 / 颜色查找。九个色域分别保留 CMYK 设置；通道混合器为 3×4 矩阵；`.cube` 支持 1D、3D、域范围、三线性插值及强度。 |
| 中文排版 | 文字工具新增竖排和两端对齐，使用系统字体回退与 UTF-16 字体/颜色区间。拼音组合期间不会由界面刷新重置 marked text。 |
| 批量导出 | 文件 → 批量导出。整图或分别导出所选图层，最长边多个尺寸（0 保持原尺寸）、前缀、网页/缩略图预设、PNG/JPEG。每次创建新文件夹，失败或取消清理暂存；显示文件进度，JPEG 衬白。所选层按画布尺寸导出，保留祖先组和蒙版依赖，不自动紧裁切。 |
| 自动化 | 文件 → 编辑命令；或随包 CLI/MCP。成功为一步撤销，任何命令失败整批丢弃。 |

### 使用边界

修边笔刷在最长边 1536 像素的工作网格上运算，再上采样到原图蒙版；它不是全分辨率发丝重建。净化颜色在应用时处理原始像素，预览在工作网格上同时显示颜色净化和蒙版；可放大及滚动检查边缘，100% 指工作网格像素。建议放大原图检查细发丝、透明物体和强烈色溢。

LUT 输入空间必须与 LUT 的制作约定匹配。可选编码 sRGB 或线性 sRGB，强度 0 保持原图。相机 Log LUT 需要独立的输入转换。本版不把 LUT/可选颜色/通道混合器保存为调整层；应用后为可撤销的像素编辑。

竖排使用 Core Text 右起列和垂直字形，西文/标点遵循系统字体的字形行为；不声称具备专业中文禁则压缩、逐字旋转及任意路径排版。缺失整套字体时显示提示，编辑后使用系统替代，保存的 PNG 在编辑前保留原貌。

## 安装与命令行

下载并解压 macOS 安装包，将 `Compositor.app` 放到“应用程序”，直接运行。界面支持简体中文和英文。普通使用不需要开发工具。

CLI 位于应用包 `Contents/MacOS/compositor-cli`。下例假设安装在系统“应用程序”：

```sh
CLI='/Applications/Compositor.app/Contents/MacOS/compositor-cli'
"$CLI" inspect ./poster.comp
"$CLI" preview ./poster.comp ./preview-new.png
"$CLI" example > commands.json
# 用 inspect 返回的 sourceFingerprint 替换 SHA256；输出目标必须尚不存在。
"$CLI" batch ./poster.comp ./commands.json ./poster-edited.comp SHA256
```

`example` 产生完整的渐变填充命令 JSON，可放入 GUI 命令面板的 `commands` 数组，也可继续添加 `{"kind":"opacity","opacity":0.6}` 等命令。名称、枚举和 JSON 字段使用固定英文；文档中的图层显示名可为中文。CLI 错误输出在 stderr，stdout 留给 JSON。

MCP 客户端示例（按实际安装位置调整 `command`）：

```json
{
  "mcpServers": {
    "compositor": {
      "command": "/Applications/Compositor.app/Contents/MacOS/compositor-cli",
      "args": ["mcp"]
    }
  }
}
```

工具：`open_project`、`new_project`、`project_state`、`edit_project`、`export_project`、`save_project`、`undo`、`redo`、`set_layer_locks`、`batch_export_project`、`close_project`。先读取状态，写入携带 `expectedRevision`，编辑还需 `documentID` 与 `expectedLockRevision`。服务维护独立内存项目；用新目标保存，再在叠绘中打开即可。详细事务/取消边界见 [编辑命令契约](edit-command-contract.md)。

`.comp` 新保存为 v12，保留旧项目副本以便与旧版交换，具体兼容规则见 [项目格式](project-format.md)。

## 构建与验收

若工程目录被 iCloud 添加 Finder 元数据，可设置 `COMPOSITOR_BUILD_ROOT` 到非同步缓存目录再构建，避免签名检查被这些元数据阻断。开发者可用现有 CLT 构建脚本 `scripts/build-clt.zsh`；CLI 入口在 `scripts/`，不进入同步的 app 源目录。此脚本打包 CLI。Xcode app target 本身不生成辅助 CLI，发布安装包使用该脚本。

```sh
./scripts/check-localization.zsh
./scripts/check-poster-clt.zsh --large
TMPDIR=/private/tmp node --test windows/tests/project.test.mjs
./scripts/build-clt.zsh
```

专项测试覆盖填充渲染和保存、v12 门控、样式、半调 alpha、LUT 解析/插值/色彩空间、竖排像素、修边撤销与原层保留、导出路径/尺寸/失败清理、命令原子性/修订/锁定。另运行第一批、液化和快捷键回归。CLI/MCP 使用真实进程协议检查。CLT 检查不等同完整 XCTest 或实际输入法/所有系统字体兼容性证明；本机没有完整 Xcode。

### 2026-10-08 验收记录

交付版本为 macOS 1.4.5（40.16），Apple Silicon 构建，包含 CLI。构建与安装包均检查代码签名和辅助程序。

| 检查 | 结果 |
|---|---|
| 海报专项 CLT | 77 项通过 |
| CLI/MCP 真实进程 | 68 项通过 |
| 液化 / 第一批 / 快捷键回归 | 89 / 78 / 868 项通过 |
| Windows 项目桥接兼容 | 20 项通过；只检查 v12 读取和保护规则 |
| 本地化 | 1,256 个候选键无缺漏；1,580 个译文检查无失败 |
| 界面实测 | 多色填充、彩色半调应用和撤销、渐变叠加、修边笔刷及副本、中文竖排和两端对齐、LUT 导入、批次一步撤销、工程保存重开、多尺寸 PNG 导出 |

界面验收修复了 LUT 文件选择框关闭后焦点未返回滤镜面板的问题；重测已显示导入文件名并可取消。多尺寸导出的实际文件为 960×640 和 480×320，比例一致。

本机 4K 合成样例中，半调约 0.447 秒、LUT 约 1.495 秒，仅为本机单次测量，不代表所有设备或大型项目的预算。完整 XCTest 尚未执行；真实拼音输入法候选/组合场景尚未确认，不能把粘贴中文和源码 marked-text 防护视为输入法验收通过。

### 2026-10-09 第二批补齐（40.17）

T06–T13 的功能入口已具备，本轮补齐日常使用和自动化旁路：

| 编号 | 完成内容 |
|---|---|
| T06 | GUI/CLI/MCP 共用图片导入、文字修改、显隐、蒙版设置/删除、主体检测与局部修边；半调/可选颜色/通道混合/LUT 完整参数；多尺寸和指定图层导出。状态返回完整文字、填充、变换及样式。整批仍一次撤销、失败不提交。 |
| T07 | 保留纯色、多色线性/径向渐变、三种图案的可编辑模型；修边仅改蒙版时，生成副本仍可再次编辑填充。 |
| T08 | 保留渐变叠加、图案叠加、内斜面高光/阴影及保存重开；命令可读写完整样式。 |
| T09 | 修边支持适合、工作网格 100%、放大/缩小、滚动平移；净化颜色进入预览并缓存；取消异步计算不会提交；仅改蒙版时保留文字/形状/填充属性。 |
| T10 | CMYK 网角、网点形状/大小/强度及三组预设可通过界面和命令使用，沿用选区/蒙版。 |
| T11 | 缺失字体提示覆盖混排中的字体区间；输入法组合期间让候选导航和 Escape 交由原生文字系统处理；保留竖排、两端对齐、UTF-16 样式与字体回退。 |
| T12 | GUI 增加文件计数、进度及取消；取消清理暂存输出；CLI/MCP 同样支持多尺寸和指定图层。 |
| T13 | GUI 与 CLI/MCP 共用完整调色参数、`.cube` 解析、强度及输入空间；缺少 LUT 的命令明确拒绝。 |

本轮修正了命令变换未同步分离蒙版位置、默认命令意外继承 GUI 多选、修边副本丢失仍有效的可编辑属性、导入蒙版需按亮度和 alpha 转换等问题。未新增项目持久化字段，格式保持 v12。

云端编译发现 LUT、颜色净化和蒙版亮度计算中的长表达式存在 Swift 类型推导超时；相关计算拆成明确类型的步骤，保持原插值及像素运算顺序。

交付版本为 macOS 1.4.5（40.17），Apple Silicon 安装包为 `Compositor-ZH-1.4.5-build40.17-macOS-arm64.zip`，安装方法同上。

| 检查 | 结果 |
|---|---|
| 海报专项 CLT | 103 项通过，含开始前取消和写出首个文件后取消的清理检查 |
| CLI/MCP 真实进程 | 86 项通过，含图片/蒙版/修边/调色/中文文字/多尺寸及指定图层导出的完整流程 |
| 液化 / 第一批 / 快捷键回归 | 89 / 78 / 868 项通过 |
| 本地化 | 1,261 个候选键无缺漏；1,585 个译文检查无失败 |
| 构建与签名 | CLT app + CLI 构建通过；安装包解压后验证代码签名与版本 |
| 界面实测 | 修边适合/100%/125% 缩放、净化颜色参数及取消；PNG 批量导出生成 960×720 和 480×360 文件 |

本机 4K 合成样例中，半调约 0.468 秒、LUT 约 1.542 秒，为单次测量。完整 XCTest 尚未执行；真实拼音候选操作尚未确认。AppKit marked-text 保留及提交机制已做定向检查，不将自动化键入的拉丁文字视为拼音验收。本轮仅修改 macOS 与相关说明，Windows 源码和构建未改变。

### 本批新增文件

- 文档：`LayerFill.swift`、`PosterEffects.swift`、`PosterColor.swift`、`ColorLUT.swift`、`EdgeRefinement.swift`、`PosterAutomation.swift`、`PosterCommandOptions.swift`。
- 导出：`BatchImageExporter.swift`。
- 渲染：`PosterPixels.c/.h`。
- 界面：`FillLayerSheet.swift`、`PosterFilterControls.swift`、`EdgeRefinementSheet.swift`、`BatchExportSheet.swift`、`AutomationSheet.swift`。
- 交付：`compositor-cli-main.swift`、`check-poster-clt.zsh`、`PosterRegressionTests.swift`、`check-poster-cli.py`、本说明。

算法为本项目实现，沿用 Compositor 的图层、像素、事务和导出路径。`.cube` 格式参考 [Adobe Cube LUT Specification 1.0](https://wwwimages2.adobe.com/content/dam/acom/en/products/speedgrade/cc/pdfs/cube-lut-specification-1.0.pdf)；MCP 使用 [官方 2025-11-25 规范](https://github.com/modelcontextprotocol/modelcontextprotocol/blob/main/docs/specification/2025-11-25/server/tools.mdx)。感谢 Robbie Tilton / Compositor 与 Terry Jia / Pentrado 提供原项目与设计思路。
