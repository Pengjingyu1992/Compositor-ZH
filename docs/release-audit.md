# 发布审查 / Release review

## 1.4.8 build 40.23 / 2026-10-11

### 隐私与发布材料 / Privacy and release materials

- 审查了当前完整源码树及所有将进入提交的新增文件（首次审查 455 个候选路径，加入发布流程后为 457 个），检查常见 API/GitHub/AWS 凭证、私钥、凭证网址和本机绝对路径；未发现匹配。源码里的 `/private/tmp` 仅用于通用构建暂存或合成测试输出，不含用户目录名。
- 检查了 12 个仓库图像资源；PNG 没有文本、EXIF 或时间戳附加块。安装包解压后对 12 个应用文件做凭证与个人路径扫描，未发现匹配；ZIP 完整性和严格代码签名校验通过，打包时已移除扩展属性。
- 本次发布附件只包含应用 ZIP、校验和及对应标签的源码归档；没有加入个人 `.comp` 项目、恢复副本、日志、本机截图/参考照片或临时产物。文档中原有的示例截图与应用图标已检查并保留。
- 已有公开 Git 历史中的主分支提交元数据包含作者邮箱。本次保留既有历史，不改写旧提交；发布新提交前会核对其作者身份。当前本地克隆是浅克隆，无法审查未下载的历史对象。
- 保留 Compositor、Pentrado 及其他上游贡献者的来源与许可证声明；Windows 目录没有本次改动。

### 发布核对 / Release checks

- 应用包版本为 **1.4.8（40.23）**，要求 macOS 26 或更新版本及 Apple silicon；应用为临时签名，未公证。
- 本机预打包的 SHA-256：`c1e91ac6371ee976aa440102827402a3db5ce0251ff6d6b2dce4a6d72d9a06ac`。正式发布附件由 GitHub Actions 从发行标签重新构建，具体 SHA-256 以附件 `SHA256SUMS.txt` 为准；不同构建的签名和归档字节可能不同。
- 本次没有在本机重跑测试套件；本机审查执行源码/元数据检查、ZIP 完整性和签名校验。最近一次定向验证记录见 [build 40.23 工具修复核查](macos-tool-fixes-validation.md)；完整 UI/单元测试状态以仓库 Actions 为准。
- 云端发布流程为 `.github/workflows/macos-release.yml`：仅处理 `v<版本>-zh.<修订>` 的 macOS 标签，执行现有构建/打包、本地化、源码和包体隐私扫描、解压签名及归档完整性检查，再上传应用 ZIP、精确标签源码 ZIP 和校验和。源码扫描覆盖受版本管理的文件及未忽略的新文件；命中只输出文件名和规则，不打印可能的密钥。流程使用仓库临时令牌，不新增个人 API Key，也不读取本机文件。Windows 发行流程保持独立。

### 正式附件复核 / Published asset verification

- 发行版：[v1.4.8-zh.3](https://github.com/Pengjingyu1992/Compositor-ZH/releases/tag/v1.4.8-zh.3)，源码提交 `69021ef6fde5c00cb500b7970f82bd9da44eeb9d`。
- [云端发布流程](https://github.com/Pengjingyu1992/Compositor-ZH/actions/runs/38147165963)全部通过。下载正式发布的三个附件后，三个文件均与 GitHub 的 SHA-256 摘要一致；两份 ZIP 与随附校验文件一致，归档完整性通过。源码归档的 457 个文件逐一与发行标签的 Git 文件内容一致。
- 正式应用 ZIP SHA-256：`ee180a518bcb1f1f135f13c77b48457e5e41d75d38946d571df15c3b2b488c0f`。
- 正式源码 ZIP SHA-256：`afc7065e4655f39681a9b1a0493bb178399a85327888fb27b2e5141418751b3b`。
- 解压后版本为 1.4.8（40.23），主程序与 CLI 均为 arm64，严格签名校验通过。对源码和应用共 469 个文件复扫，未发现扫描规则命中；这不构成对任意未知凭证格式的保证。
- [独立 Verify 流程](https://github.com/Pengjingyu1992/Compositor-ZH/actions/runs/38147165891)中，CLT 构建、本地化及海报检查通过；Xcode 测试构建失败：`EditableRecoveryRegressionTests.swift` 六处跨 actor 读取 `directory`，测试因此未执行。此结果不记作完整单元测试通过；失败位于测试代码，发行应用的构建与打包通过。

## 历史记录：1.4.5 build 40.10 / 2026-10-02

Date: **2026-10-02**. Version: **1.4.5**, build **40.10**, release **v1.4.5-zh.2**.

## 隐私与密钥 / Privacy and credentials

审查范围包括发布源码、注释、文档、配置、图片附带元数据、应用内文件与二进制字符串，以及本地可用的 Git 对象。扫描了常见 API Key、GitHub/Slack/AWS/Google token、私钥、凭证链接、硬编码密码、个人路径、邮箱、手机号与本机用户名，并人工复核命中和发布配置。

**发布材料未发现个人隐私、硬编码凭证或 API Key。** 图片压缩数据中的短字符串误报已复核；11 个 PNG 的可选附带元数据已移除，压缩像素流保持相同，ICNS 随之重建。

The review covered release source, comments, documentation, configuration, image metadata, bundle contents and binary strings, and locally available Git objects. It checked common credential formats, private keys, credential URLs, assigned passwords, personal paths, email addresses, phone numbers, and the local machine username, followed by manual review of findings and publishing configuration. **No personal data or embedded credentials were found in the release materials.** Pattern scanning is a review aid, not proof against every possible secret format.

- 个人运行日志、备份、恢复项目、偏好文件、截图与配色参考照片未纳入。 / Personal logs, backups, recovery projects, preferences, screenshots, and the reference photograph are excluded.
- 必要的技术注释和原作者许可保留。 / Technical comments and upstream license notices are retained.
- 原本地仓库的暂存状态及历史保留；公开仓库从干净源码快照开始。可用的原仓库为浅克隆，未声称扫描未下载的历史。 / The original local checkout, index, and history are preserved. The public repository begins with a clean snapshot; the original shallow clone's unavailable history was not scanned.
- 新提交使用 GitHub noreply 身份。 / New commits use a GitHub noreply identity.
- 更新入口改为本仓库 Releases；不打包 Sparkle，不使用原作者更新签名或开发者账号。 / Updates open this repository's releases; Sparkle and upstream update/signing configuration are not distributed.

## 本次检查 / Checks for this release

- 完整 CLT 应用编译成功，使用 macOS 26 SDK。 / Full CLT application build passed with a macOS 26 SDK.
- **1,058** 个源码候选本地化键：缺失、未译、未解析均为 **0**。 / 1,058 candidate localization keys, with zero missing, untranslated, or unresolved entries.
- **1,320** 项翻译占位符兼容检查：**0** 失败。 / 1,320 translation format-signature checks, zero failures.
- Python、zsh 脚本与 plist/pbxproj 格式检查通过。 / Script syntax and plist/project-format checks passed.
- 包内版本、应用 ID、两种语言名称、图标与两份许可证核对通过。 / Version, bundle identifier, both localized names, icon, and both licenses were verified.
- ZIP 与构建应用逐文件一致；解压后严格签名验证通过。 / ZIP contents match the built app file for file; strict signature verification passed after extraction.
- 发布附件提供 SHA-256；上传后重新下载并比较。 / Release assets include SHA-256 checksums and are downloaded again for comparison after upload.

## Xcode compatibility fixes

The initial CI run exposed string-symbol generation errors for runtime localization keys and a SwiftUI expression that exceeded the Xcode 26.6 type-checker budget. Symbol generation is disabled because localization uses stable source keys; the view chain is split into smaller opaque views without changing the UI. Nested `#require` expressions in three existing test cases are split into intermediate values for Swift Testing compatibility, preserving the same assertions. Signing is staged outside synchronized folders to keep filesystem metadata from invalidating ad hoc signatures.

## 验证边界 / Verification limits

本机只有 Command Line Tools，本次未在本机运行完整 Xcode 测试或 UI 测试。GitHub Actions 配置了 CLT 构建、本地化检查及 Xcode 单元测试，运行结果请查看仓库 Actions，不将待完成的 CI 视为通过。

Only Command Line Tools are available locally. Full local Xcode and UI tests were not run for this release. GitHub Actions is configured for the CLT build, localization checks, and Xcode unit tests; consult Actions for actual results.

此前的中英切换、正常退出与重开已验证；本次未重新执行完整人工编辑流程。PSD 已做自回读与独立读取器比对，但 Photoshop/Photopea 实际打开仍未验证。安装包为临时签名，未作 Apple Developer ID 公证。

Language switching and normal quit/reopen were verified in the preceding build. This release did not repeat the complete manual editing workflow. PSD round trips and an independent reader were checked previously; opening exports in Photoshop/Photopea remains unverified. The package is ad hoc signed, not Apple notarized.
