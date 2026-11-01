# Windows 启动 Issue #5 处理记录（2026-11-01）

检查时仓库只有一个未关闭 Issue：[Windows 11 x64 安装与核心回归反馈 #5](https://github.com/Pengjingyu1992/Compositor-ZH/issues/5)。其主体要求补充启动诊断和隐私友好的反馈模板；后续评论说明，曾通过隐藏窗口方式启动应用，正常再次启动未显式显示隐藏窗口。该反馈不构成普通双击启动崩溃的证据。

## 修复与复现

修复提交：[`424c7a5`](https://github.com/Pengjingyu1992/Compositor-ZH/commit/424c7a5fd6fa3ac25ae4606311ae43e9c5c39b88)，开发分支 `codex/desktop-macos-parity`。

- 单实例通知现在检查窗口是否可用，恢复最小化状态、显示隐藏窗口，再请求焦点。重复启动继续使用现有编辑器，不重建项目或清空未保存修改。操作系统仍决定是否允许前台焦点。
- 新增打包应用回归：打开合成项目、改动不透明度、隐藏窗口，然后实际启动第二个可执行进程；确认原进程收到单实例通知，第二个进程正常退出，原窗口显示、窗口数量仍为一，活动文档、不透明度与撤销历史保留。再从可见状态重复启动并撤销，确认源 manifest 字节未改动。
- 在修复前的构建 `ffda5eb`（应用代码来自 `b674ae5`）运行同一新增测试，单实例通知确实到达，但窗口仍隐藏，`isVisible()` 为 false，测试失败。修复后通过；没有放宽可见性或文档保护断言。
- [Windows 安装说明](windows-install.md#启动排查与反馈) 补充进程存在但窗口不可见的检查、常规窗口启动、可选本地日志、版本和下载校验字段，以及绘画、真实中文 IME、撤销、保存重开、PNG/PSD 的分项人工验收。
- 新增 [Windows 反馈表单](../.github/ISSUE_TEMPLATE/windows-feedback.yml)，以不同阶段分别记录启动证据，日志可选。表单合入默认分支后才会出现在 New issue 入口；此前可复制安装说明中的表格。

## 验证

本地 Linux 打包应用检查：类型检查和构建通过；核心测试 **255/255**；启动、查看、编辑、撤销、保存、恢复保护及 PNG/PSD 导出针对性 GUI 检查 **14/14**，无失败、跳过或重试。反馈表单通过 YAML 解析与字段有效性检查，8 个输入字段 ID 唯一。

另外在 Linux 云环境用文档中的 Chromium 日志参数启动同一打包应用，确认窗口可见并生成本地日志；仅记录文件存在及大小，未发布日志内容。这不是 Windows PowerShell 命令或真实 Windows 桌面的实测。

最终应用提交 `424c7a5` 的完整平台 CI：

| 平台 | 完整 GUI 结果 | 安装包与其他检查 | CI |
| --- | --- | --- | --- |
| Windows x64 | **111 项通过，3 项 Linux 专属跳过，0 失败** | 类型、255 项核心测试、独立 PSD/图像读取、EXE/ZIP、许可证、校验值及包隐私审查通过 | [41272352614](https://github.com/Pengjingyu1992/Compositor-ZH/actions/runs/41272352614) |
| Linux x64 | **114/114 通过，0 失败、0 跳过** | 类型、255 项核心测试、独立 PSD/GIF/EPS/图像读取、AppImage/Deb/tar.gz、提取后的 AppImage 启动回归、许可证、校验值及包隐私审查通过 | [41272352657](https://github.com/Pengjingyu1992/Compositor-ZH/actions/runs/41272352657) |

两次完整平台运行均成功，新增的真实二次启动测试包含在其中。Windows Actions 产物 `compositor-windows-x64`（270 MB）与 Linux 产物 `compositor-linux-x64`（355 MB）包含本次构建；它们是 Actions 构建包，保留期 14 天，并未替换正式 Releases。具体 Actions 产物摘要与本地检查元数据见 [verification.json](desktop-issues-2026-11-01/verification.json)。

## 隐私与范围

- 源码检查：232 个桌面文件、796 个双语键，未发现匹配的私有路径或凭据。本地 Linux 应用 ASAR 扫描 215 项、163 个文本文件，未发现匹配的私有路径、凭据、源映射、测试工程或环境文件。本地 Linux `app.asar` SHA-256：`03d92ae8328bca727f91f38a84060661ab581a9c5cbc3dc0724871f0d81c7f60`。模式扫描不能代替对所有潜在个人信息的人工判断。
- 唤醒修复没有增加日志、遥测、网络请求或项目内容上传；未增加依赖，未改变项目格式。
- 启动日志仅由用户显式传入 Chromium 日志参数后写入本机，可能含用户名、路径、网址与设备信息。文档要求先正常退出已有实例，仅用合成作品复现，分享前检查和删去隐私，只附必要摘录；不要求提交个人工程、恢复副本、应用数据目录或密钥。
- 回归使用合成项目和独立设置目录；完整运行日志、失败 trace 和本机启动日志不提交仓库。
- 原生 macOS 源码、项目、测试和发布配置未改动；未合入 `main`、创建发行标签或修改全局 Latest。此次产物为开发分支及 CI 构建，不代表旧公开安装包已包含修复。
- 云端软件 GPU 验证不能代替真实 Win10/11 设备、实际 GPU、中文 IME、高 DPI、多显示器与外部 PSD 应用的人工验收。
- 原生 macOS [Verify 41272352633](https://github.com/Pengjingyu1992/Compositor-ZH/actions/runs/41272352633) 的 Xcode 单元测试退出码为 65；同分支基线 `ffda5eb` 的 [Verify 40823795259](https://github.com/Pengjingyu1992/Compositor-ZH/actions/runs/40823795259) 也失败。本轮没有修改原生 Mac 文件，也没有取得该失败的完整日志，不能声称已定位其具体原因；上述 Windows/Linux 检查不代表仓库所有工作流通过。

提交含 `Fixes #5`，合入默认分支后 GitHub 会自动关闭该 Issue；开发分支提交不会立即关闭它。本记录不声称 Issue 已关闭。
