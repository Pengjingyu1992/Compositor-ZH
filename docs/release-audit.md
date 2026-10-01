# 发布审查 / Release review

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

The initial CI run exposed string-symbol generation errors for runtime localization keys and a SwiftUI expression that exceeded the Xcode 26.6 type-checker budget. Symbol generation is disabled because localization uses stable source keys; the view chain is split into smaller opaque views without changing the UI.

## 验证边界 / Verification limits

本机只有 Command Line Tools，本次未在本机运行完整 Xcode 测试或 UI 测试。GitHub Actions 配置了 CLT 构建、本地化检查及 Xcode 单元测试，运行结果请查看仓库 Actions，不将待完成的 CI 视为通过。

Only Command Line Tools are available locally. Full local Xcode and UI tests were not run for this release. GitHub Actions is configured for the CLT build, localization checks, and Xcode unit tests; consult Actions for actual results.

此前的中英切换、正常退出与重开已验证；本次未重新执行完整人工编辑流程。PSD 已做自回读与独立读取器比对，但 Photoshop/Photopea 实际打开仍未验证。安装包为临时签名，未作 Apple Developer ID 公证。

Language switching and normal quit/reopen were verified in the preceding build. This release did not repeat the complete manual editing workflow. PSD round trips and an independent reader were checked previously; opening exports in Photoshop/Photopea remains unverified. The package is ad hoc signed, not Apple notarized.
