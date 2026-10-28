# macOS 风格桌面 UI 验证 · 2026-10-29

应用代码提交：`0e24e40`；分支 `codex/desktop-macos-parity`。用户明确选择“尽量贴进MacOS版UI风格”，本次只调整 Windows/Linux 共用界面。原生参考为 macOS 40.41（`f8b1457`）；不声明像素级复刻。

本次统一中性灰与蓝色交互色，新增跟随系统／浅色／深色外观和旧设置迁移；将项目标签并入顶部工具栏，固定工具轨的导航与颜色控件，新增检查器开关及导出入口。AI 对新配置默认折叠，保留已有偏好。紧凑窗口保留选中图层可见空间，参数栏支持横向滚动。

详细决策见 [DESIGN.md](../DESIGN.md)，[实际截图与复核](../design-previews/2026-10-29-desktop-ui/IMPLEMENTATION.md) 包含桌面浅／深色和中文紧凑窗口。全部使用合成项目和隔离设置。

| 检查 | 结果与证据 |
|---|---|
| 共享模型与类型 | 251 项单元、TypeScript 通过；旧外观设置迁移保留网格、标尺和色板，拒绝非法外观值 |
| 源码与隐私 | 220 个桌面文件、766 个双语键审查通过；最终应用 ASAR 中 213 个条目／161 个文本文件扫描无匹配私有路径或凭据 |
| 独立格式读取 | psd-tools、Pillow、Ghostscript 对 PSD/GIF/EPS/PNG/JPEG/TIFF/WebP/AVIF/PDF、ICC 与四通道 CMYK 检查通过 |
| 外观与布局 GUI | 显式浅／深色、跟随系统、重启恢复、检查器键盘开关、AI 展开与恢复、中文长名称、紧凑窗口选中图层完整可见及不变画布采样通过 |
| 本机完整 GUI | 同一最终应用 83/83 通过，无跳过、失败或重试（16.0 分钟） |
| Windows 云端 | [40738733764](https://github.com/Pengjingyu1992/Compositor-ZH/actions/runs/40738733764) 成功：80 项 GUI 通过、3 项 Linux 专属跳过；NSIS/ZIP、校验值、许可证和包隐私审查通过 |
| Linux 云端 | [40738733928](https://github.com/Pengjingyu1992/Compositor-ZH/actions/runs/40738733928) 成功：83/83 GUI；提取后的 AppImage 启动器回归、AppImage/Deb/tar.gz 三格式、校验值、许可证和包隐私审查通过 |

本机完整 GUI 对应应用 ASAR SHA-256：`16adac9ea3c986a849f1ae9e72e641bb64ec04037c9b272b19557919d4243248`。GUI 与应用源码扫描使用该同一不可变构建；安装器、容器和完整许可证的验收以平台 CI 的包审查为准。

复核中实际保留的失败：首个候选的深色面板仍为浅色，定位为 Vite 对 `light-dark()` 的旧 CSS 兼容转译；改为内置 Chromium 的 CSS 目标后原断言通过。随后新增的中文紧凑窗口完整可见断言发现第二个图层部分被裁切，通过保留图层空间并收起类型副标题修正；未放宽断言。截图禁用瞬时过渡，避免把主题切换中间帧当作最终颜色。正文对比度为浅色 14.23:1／深色 11.64:1，主要按钮分别为 5.42:1／5.48:1；八组主要文字／背景配对均达到 4.5:1。初期和修正后的报告分开保留，没有覆盖失败证据。

原生 macOS 目录相对本次 UI 工作之前的 `e94b347` 无改动。附带触发的原生 `Verify` 工作流中 Xcode 单元任务报退出码 65；此前 `e94b347` 的[原生任务](https://github.com/Pengjingyu1992/Compositor-ZH/actions/runs/40705695395) 同样报 65，本轮[原生任务](https://github.com/Pengjingyu1992/Compositor-ZH/actions/runs/40738734010)不计为通过。本轮未定位其根因，也没有为此修改 macOS。

代码与云端安装包属于开发分支，未新建发行标签、发布正式版或更改 macOS／全局 Latest。真实设备的高 DPI、输入法、压感与硬件 GPU 验收仍待完成；整体功能对齐的剩余项见 [功能对照表](windows-linux-macos-parity.md)。
