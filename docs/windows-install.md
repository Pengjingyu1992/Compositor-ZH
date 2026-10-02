# 叠绘 / Compositor Windows 安装说明

## 下载和安装

1. 打开 [Windows 预览版发行页](https://github.com/Pengjingyu1992/Compositor-ZH/releases/tag/windows-v0.1.0-alpha.2)。不要使用仓库的 `releases/latest`，那个入口保留给 macOS。
2. **Windows 10 22H2 或 Windows 11，64 位 Intel/AMD（x64）**：下载 `Compositor-Windows-0.1.0-alpha.2-x64.exe`，运行后按安装向导选择目录。不需要 Node.js、npm、Xcode 或 API Key。当前不提供 Windows ARM64/32 位原生包。
3. 或下载同名 `.zip`，**完整解压**到一个目录，运行其中的 `Compositor.exe`。不要只复制 EXE；`resources`、DLL、语言资源和许可证必须一起保留。
4. 当前为未签名社区预览版，Windows 可能显示发布者未知。先核对下载来源和下方校验和，仅在确认来源后按系统提供的选项打开；不要关闭 Defender。
5. 第一次启动默认简体中文。右上角选择 **English / 简体中文** 即时切换，关闭后重新打开仍保留。

安装版和 ZIP 版都使用 `%APPDATA%\Compositor-Windows\preferences.json` 保存语言设置。设置只存语言，不存项目路径、不上传项目。它们共享 Windows 语言设置；与 macOS 设置完全独立。卸载保留设置，想重置时先退出再删除该文件。

最低目标系统来自 Electron 的 Windows 10+ 支持范围；本版只发布 x64，**真实 Windows 10/11 设备验收尚未完成**，不能将云端 Windows Server 构建视为设备兼容性保证。

## 打开 macOS 项目

1. 在 macOS 版保存项目后，把**整个 `作品.comp` 文件夹**复制到 Windows。必要时先在 Mac 上压缩整个项目，再在 Windows 解压。
2. 项目内应包含 `manifest.json`、`images/` 及所有图层 PNG；`QuickLook/Preview.jpg` 是可选的已保存预览。
3. 点击“打开项目”或 `Ctrl+O`，在文件夹选择器中直接选中 `.comp` 文件夹，然后确认“打开项目”。不要只选择 manifest，也不要选择快捷方式或目录链接。
4. 也可以把**单个完整 `.comp` 文件夹**拖到窗口中打开；拖入多个文件夹会提示重新选择。
5. “适合窗口” / `Ctrl+0` 适合显示，`Ctrl+1` 显示 100%；`Ctrl+滚轮` 或工具栏 `+ / −` 缩放，拖动画布区域平移。右侧点击图层查看原始属性。

本版**没有编辑、保存或覆盖源文件的入口**，`Ctrl+S` 也不会保存。文字和形状显示项目已有的 PNG，不需要重新匹配中文字体。原始 metadata 中的英文枚举/字段名按源文件保留，不是可编辑表单。

## 项目查看与反馈

- **重新加载**：工具栏 ↻ 或 `Ctrl+R`，读取源文件当前内容。读取失败保留已打开快照并显示错误；应用不会自动改写项目。
- **关闭项目**：工具栏 × 或 `Ctrl+W`，回到欢迎页并释放项目和渲染资源；加载中的旧结果会被丢弃。退出程序仍可用 `Alt+F4` 或文件菜单。
- 右侧可以按名称搜索图层（中文/英文均可），点击组名前的箭头折叠或展开。搜索时临时显示匹配层的父组，清除搜索恢复原折叠状态。
- 点击“复制兼容性报告”后，可粘贴到问题反馈。报告只含应用/格式版本、尺寸、图层及资源数量、预览来源、兼容性原因和内存估计，不含项目名、路径、图层名/ID或原始元数据。**不会自动发送**；分享前仍可查看剪贴板内容。
- 打开路径仅在当前会话内用于重载，关闭后释放；不会添加最近文件列表或写入语言设置。

## 预览边界

- 支持 `.comp` 格式版本 1–11、sRGB；读取并检查图层、目录关系、资源及大小限制。
- Pentrado 合成基础像素层、正常混合、可见性、不透明度、位置/缩放/旋转/翻转、组内继承不透明度和图层联动栅格蒙版。**macOS 黄金图比对尚未完成**，此模式标为“图层预览”，不宣称像素完全一致。
- 其他 23 种混合、调整层、效果、剪贴关系、组蒙版、独立蒙版位置、最近邻采样和未知字段：显示明确原因并使用 `QuickLook/Preview.jpg`。这只是 **macOS 上次保存的预览**，可能过时或尺寸较小；不是在 Windows 新渲染出来的完整作品。
- 没有可用的保存预览时，显示说明及图层/属性；**不显示删掉复杂层后的残缺合成图**。
- 读取限额：manifest 4 MiB、每个资源 64 MiB、累计编码资源 256 MiB、图层 10,000 个、画布边长 30,000 px。图像/蒙版像素各不超过 1 亿。独立合成还受 1600 万画布像素、768 MiB 估算工作预算和实际 GPU 纹理上限限制；超过时使用保存预览，不缩小原始项目数据。
- 必须能用 WebGL2 与 `EXT_color_buffer_float`；不满足时尝试保存预览。本版没有 CPU 编辑渲染器，也没有导出大画布功能。
- 固定使用 npm `pentrado@0.1.1`，其接口早于当前作者仓库的 quad/presentCanvas 实现。适配层先生成整画布位置缓冲，再由 Pentrado 合成；每层/蒙版的 CPU、GPU 副本均计入预算。多层大画布因此可能提前回退，不宣称已有作者仓库最新的分块性能。
- 右侧“后续编辑范围评估”按图层显示基础、PNG 回退、复杂只读三类；**当前全部只读**。这些数字只是这个项目的结构分类，不是经过实机验证的可编辑比例。

## 校验下载

发行页同时提供 `SHA256SUMS.txt`。在 PowerShell 中执行：

```powershell
Get-FileHash .\Compositor-Windows-0.1.0-alpha.2-x64.exe -Algorithm SHA256
```

与校验文件中对应文件的 SHA-256 相同再安装。ZIP 同样可以校验。

## 开发构建（Windows）

安装 Node.js 24 LTS 和 Git，克隆仓库后：

```powershell
git clone https://github.com/Pengjingyu1992/Compositor-ZH.git
cd Compositor-ZH\windows
npm ci
npm run build
npm start
```

生成 x64 安装向导和 ZIP：

```powershell
npm run package:win
```

输出在 `windows/release/`。无需 macOS SDK。应用入口 `windows/` 独立于 `Compositor/` 的原生 Swift 应用。

云端工作流 `Windows verify and package` 在 Windows Server 2025 上执行源码审查、本地化键检查、类型检查、项目协议/往返检查、打包、软件 GPU Electron 启动/预览/语言持久化检查和许可证/包内容审查。按照本次要求，**开发者本机不运行测试或应用构建**。

## 发布与 macOS 更新隔离

- 使用 `windows-v*` 标签，不使用 macOS 的 `v*` 标签。`Windows release candidate` 构建候选产物，不自动公开发行。
- 下载云端产物、检查内容/许可证/校验和后创建草稿，绑定确切构建提交。发布时使用 **prerelease** 和 **make_latest=false**；创建和草稿转公开时都明确指定。
- 发布前记录 macOS latest 的 release ID/tag，发布后再请求 `/repos/Pengjingyu1992/Compositor-ZH/releases/latest` 校验它未改变。异常时恢复原 macOS latest，并再次核对。未来 Windows 稳定发行也遵守这个纪律。
- 不改动 macOS 更新代码或安装包，不复用其设置目录。本阶段没有 Windows 自动更新器。

## English installation summary

Download the x64 EXE or ZIP from the [Windows prerelease](https://github.com/Pengjingyu1992/Compositor-ZH/releases/tag/windows-v0.1.0-alpha.2). Run the installer, or extract the entire ZIP and launch `Compositor.exe`. Node.js is not required. Packages are unsigned; verify their SHA-256 before opening. Target: Windows 10 22H2 / Windows 11 x64; actual hardware acceptance remains pending.

Copy the **entire `.comp` folder** from macOS and select it with **Open project / Ctrl+O**. You can also drop one complete `.comp` folder into the window. Use Ctrl+0 to fit, Ctrl+1 for actual size, Ctrl+wheel to zoom, and drag to pan. Ctrl+R reloads the source; Ctrl+W closes the project. Search layer names and collapse groups in the sidebar. Copy compatibility report explicitly copies aggregate data to the clipboard; it contains no project names, paths, layer names/IDs, or raw metadata and is never sent automatically. The top-right selector changes English/Simplified Chinese immediately and persists under `%APPDATA%\Compositor-Windows`.

This is a read-only preview, not the full editor. Basic Normal layers use the Pentrado compositor with explicit sRGB spaces; macOS golden-image fidelity is not yet certified. Unsupported properties use the preview last saved by macOS, which may be stale. Without that preview, only layers/properties are shown. There is no save, painting, PSD, project upload, or telemetry.

Thank you to [Robbie Tilton, Compositor](https://github.com/robbietilton/Compositor) and [Terry Jia, Pentrado](https://github.com/jtydhr88/pentrado). License details are in [Windows notices](../windows/THIRD_PARTY_NOTICES.md).
