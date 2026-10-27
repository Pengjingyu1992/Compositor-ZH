# 叠绘 / Compositor Linux

Linux 版与 Windows 版共用 Vue/Electron 编辑器、Pentrado 合成内核和 `.comp` 项目桥接。图层绘画、中文文字、形状、蒙版、选区、调整、滤镜、动画 GIF、PSD/PNG/EPS 转换、撤销、保存和恢复沿用同一实现。Linux 使用独立应用标识、桌面菜单、配置和恢复目录。macOS 原生程序仍使用 Swift/AppKit/Metal。

首批目标为 **Linux x86_64**，提供 AppImage、Deb 安装包与 tar.gz 便携包。当前在 Debian 13 云环境进行验证，CI 配置为 Ubuntu 24.04。真实 GNOME/KDE、Wayland/X11、中文输入法、高 DPI、硬件 GPU 和 Photoshop/Photopea 验收仍待完成；ARM64 尚未提供。

## 安装与启动

发行文件名称包含版本号，例如 `Compositor-Linux-0.4.0-alpha.1-x86_64.AppImage`、`Compositor-Linux-0.4.0-alpha.1-amd64.deb` 和 `Compositor-Linux-0.4.0-alpha.1-x64.tar.gz`。已发布的安装包见 [Linux 0.4.0-alpha.1 预发布](https://github.com/Pengjingyu1992/Compositor-ZH/releases/tag/linux-v0.4.0-alpha.1)；源码构建输出在 `linux/release/`。工作分支上的后续修复不代表该预发布的安装包已更新。

下载或复制完整候选包与 `SHA256SUMS.txt`，在同一目录校验：

```sh
sha256sum --check SHA256SUMS.txt
```

Debian/Ubuntu 推荐 Deb 包，安装后可从应用菜单打开“叠绘 Linux”或运行 `compositor-linux`：

```sh
sudo apt install ./Compositor-Linux-0.4.0-alpha.1-amd64.deb
compositor-linux
```

已发布的 `0.4.0-alpha.1` Deb 漏列 `libgbm1` 依赖；如果启动提示缺少 `libgbm.so.1`，运行 `sudo apt install libgbm1`。源码已补齐该依赖及包审查，需下一次发行才会进入下载包。

AppImage 可直接运行：

```sh
chmod +x Compositor-Linux-0.4.0-alpha.1-x86_64.AppImage
./Compositor-Linux-0.4.0-alpha.1-x86_64.AppImage
```

AppImage 使用静态运行时，也支持 `--appimage-extract-and-run`。在不支持挂载的环境可执行 `--appimage-extract`，然后运行 `squashfs-root/AppRun`。tar.gz 需完整解压，再运行其中的 `compositor-linux`；保留 `resources`、许可证和运行时文件。

便携包仍需系统 GTK 3、NSS、ALSA、GBM 等桌面库。Deb 包声明运行依赖；开发分支的轮廓/路径文字还需要 `fontconfig`（提供 `fc-match`/`fc-list`，新 Deb 已声明）；中文文字建议安装 `fonts-noto-cjk`。程序保留 Chromium 沙箱，不在发行启动器中自动添加 `--no-sandbox`。Ubuntu 24.04 等限制非特权用户命名空间的系统优先使用 Deb 包，其安装脚本按系统能力配置沙箱与 AppArmor。遇到沙箱启动错误时，检查系统或组织的沙箱策略，不要关闭系统防护。

## 项目与设置

- 通过“打开项目”选择整个 `.comp` 文件夹，也可拖入完整项目目录。复制作品时保留所有资源。
- 开发分支已读取格式版本 1–17；v17 原始 PNG 保留其字节，以经过方向/ICC 处理的 8 位 sRGB 代理编辑。高级路径、滤镜栈等属性的完整编辑能力以功能对照表为准。已发布旧包仍只接受 v1–16，不要手动修改版本号。
- 中文 / English 即时切换，偏好保存到下次启动。Linux 与 Windows 包使用不同标识与设置目录。
- 配置默认在 `${XDG_CONFIG_HOME:-$HOME/.config}/Compositor-Linux/`，恢复副本位于其中的 `recovery/`，保存日志位于 `save-journals/`。
- 保存使用分阶段写入、回读校验、完整备份与中断恢复；拒绝覆盖已被外部修改的项目。未知字段与未改动资源保持原样。
- 共享编辑功能和快捷键见 [编辑器工具说明](windows-full-editor.md)，文件格式以 [项目格式](project-format.md) 和实际读取器校验为准。暂不支持的可见属性使用保存预览并限制编辑。

## EPS 与可选 AI 助手

普通 EPS 导入需 Ghostscript 10：Debian/Ubuntu 可运行 `sudo apt install ghostscript`。Linux 自动检查 `/usr/bin/gs` 和 `/usr/local/bin/gs`；自定义安装可用绝对路径设置 `COMPOSITOR_GHOSTSCRIPT` 后重启。叠绘自己的像素 EPS 无需此组件。Ghostscript 不随安装包分发。

基础编辑器完全离线，无需账号或 API 密钥。可选 AI 助手把提示词与图层元数据发送到你配置的接口；不发送图像像素或整个项目。密钥只在 Secret Service（GNOME Keyring）或 KWallet 可用时加密保存。没有可用密钥环、密钥环被锁定或 Chromium 使用 `basic_text` 回退时，程序不保存密钥，并显示系统加密不可用。先启动并解锁桌面密钥环，再使用助手。

隐私检查的范围、AI 请求字段、密钥保存方式及审查限制见[Linux 隐私审查](linux-privacy-review.md)。

后续修复和优先事项见 [Linux / Windows 完善记录](linux-windows-review.md)。

## 开发与验证

共享源码暂保留在 `windows/`，依赖使用现有锁文件；Linux 配置、启动器与发行说明在 `linux/`。需要 Node.js 24（项目要求至少 22.12）、Python 3、Git 和 Linux 桌面库。

```sh
cd windows
npm ci
npm run typecheck
npm test
npm run package:linux
npm start
```

`npm ci` 显式安装并校验 Electron 运行时。只需快速构建可运行目录时执行 `npm run package:linux:dir`。完整打包生成三种文件；AppImage 使用锁定版本的 electron-builder 下载器校验工具包和静态运行时，并使用本仓库的 `linux/AppRun`。

```sh
cd windows
xvfb-run -a -s '-screen 0 1440x1000x24 -nolisten tcp' npm run smoke
npm run audit:linux
```

GUI 检查需要 D-Bus 与已解锁的桌面密钥环，完整准备方式见 [Linux CI](../.github/workflows/linux-verify.yml)。测试隔离用户数据，只使用合成作品和本地模型模拟服务。`COMPOSITOR_SMOKE_NO_SANDBOX=1` 仅供不能提供 Chromium 沙箱的 CI 容器；正常桌面保持沙箱。`COMPOSITOR_SMOKE_EXECUTABLE` 可指向解压后的 AppImage/Deb 二进制，验证实际安装内容。

`npm test` 在 `windows/playwright-report/codec-fixtures/` 生成独立 PSD/GIF/EPS 校验样本；安装 `psd-tools==1.23.0` 后运行 `python tests/independent-psd.py` 和 `python tests/independent-image-codecs.py`。前者检查分层 PSD，后者用 Pillow 检查 GIF 帧、时间和像素，并用 Ghostscript 执行 EPS 检查尺寸、颜色和透明背景白色合成。GUI JSON 报告保存在 `windows/playwright-report/smoke-results.json`，局部测试使用 `--reporter=list` 可保留完整报告。包审查检查各格式中的源码、应用标识、桌面文件、依赖许可证，并写入 `SHA256SUMS.txt` 和 `PACKAGE-REVIEW.json`。功能覆盖、已修复问题及实机限制见 [Linux 功能验证报告](linux-function-validation.md)。

Linux 候选构建使用 `linux-v*` 标签，与 Windows/macOS 发行通道分开。分支推送只验证并保存 CI 产物；推送 `linux-v*` 标签会触发完整验证，成功后校验包名和 SHA-256 并自动创建 prerelease（`--latest=false`）。真实桌面验收前保持预发布，不能替换 macOS `/releases/latest`。发布标签一旦对应公开安装包，就应保持不变，后续修复使用新版本标签。

## English summary

The Linux x64 edition shares the Vue/Electron editor with Windows, with its own identity, desktop integration, settings and recovery directory. Build from `windows/` with Node 24: `npm ci`, `npm run package:linux`. Outputs are an AppImage, Debian package and portable tar.gz under `linux/release`. Verify `SHA256SUMS.txt`; use the Deb package on Debian/Ubuntu or keep the complete portable distribution together.

The editor works offline. General EPS import needs separately installed Ghostscript 10. The optional AI assistant requires an unlocked Secret Service/KWallet backend to store an API key; the insecure `basic_text` fallback is rejected. Chromium sandboxing remains enabled in distribution launchers. Debian 13 cloud validation and Ubuntu CI do not establish acceptance on real GNOME/KDE, Wayland/X11, IME, high-DPI or hardware-GPU setups. Linux releases remain separate prereleases. See [third-party notices](../linux/THIRD_PARTY_NOTICES.md).
