# macOS workspace polish and continuous previews

Build 40.25 implements the first batch of workspace and responsiveness improvements. It preserves the existing project format.

## 本批结果

本机版本为 1.4.8（40.25）：空文档简化、静态图片收起动画栏、统一数字输入框与选中状态、排版弹层、简洁状态栏及工具帮助、中英文术语、液化连续预览均已实现。实际操作发现的“取消液化后图层按钮留灰”也已修复并复核。

定向检查共 1,081 项通过；构建、本地化、隐私模式扫描与严格签名检查通过。紧凑窗口检查采用 865×561 点。完整 Xcode 测试、精确 800×520 布局与完整英文/辅助功能人工检查未执行；小素材耗时不代表大图性能。

## Workspace

- Empty documents show a short creation hint instead of disabled tool parameters, blend controls, locks, and layer actions.
- The timeline appears for animation documents. Static documents can create an animation using Image → Create Animation.
- Numeric fields share a 26-point control height, trailing alignment, monospaced digits and focus outlines inside the existing 42-point tool header. Text alignment and advanced Liquify tools share selected and hover styling.
- Typography keeps font, size, color and alignment in the header; vertical text, path offset, arc bend, tracking and leading are in a labeled popover.
- The status bar shows the current tool's first instruction. The Tool Help button opens all keyboard and mouse instructions. The color descriptor states the actual sRGB / 8-bit RGBA working format; it does not infer opacity from the background.
- New Canvas keeps its compact size and adapts its material and border to Reduce Transparency and Increase Contrast. The Chinese transform sampling label now describes interpolation quality.

## Liquify preview lifecycle

One render runs at a time for a workspace. A completed frame from the current edit branch is displayed even when newer pointer input has arrived; another render then catches up to the latest field. Undo, redo and reset advance the branch, preventing an older branch from replacing the restored preview.

Cancel and Apply stop preview publication and invalidate the job identity. A failed apply can resume previews only while the same workspace still owns the document revision. The existing document, layer and lock guards remain in the final commit path. Render failures keep the last valid frame and expose an error. Layer permissions observe the Liquify modal even while an unobserved edit owner blocks editing; releasing that owner before dismissing the modal refreshes controls after cancellation.

## Local performance recording

Recording is disabled by default. Launch the executable with `COMPOSITOR_PERFORMANCE=1` to enable bounded in-memory timing and local unified-log events. Operations are fixed labels: tool switching, brush updates, brush commits, Liquify previews, filter previews and explicit GPU waits. No file names, document contents, pixels or user identifiers are recorded; there is no network transmission or automatic log file.

Each operation keeps at most 512 recent samples for median/p95 plus a lifetime count and maximum. Local log events are limited to the first and every 60th sample. These timings measure the named code scopes, not input-to-photon latency or process memory.

Run the existing CLT checks with recording enabled:

```sh
COMPOSITOR_PERFORMANCE=1 ./scripts/check-liquify-clt.zsh --shortcuts
```

The harness prints the recorded summaries. The optional `--large` scenarios are separate from the normal first-batch checks. Users do not need developer tools to use the installed application.

## Regression scope

The Liquify checks cover completed frames during newer input, convergence, undo/reset branch rejection, cancellation, resumption, invalid timing samples and concurrent recording, alongside the existing rendering, history, owner, lock and shortcut checks. UI review covers empty, static, text and animation workspaces. The results below describe the completed validation.

## Validation record

- CLT regression: 103 Liquify checks, 78 foundational editing checks and 900 shortcut checks; zero failures.
- Localization: 1,455 source candidates, no missing/untranslated/unresolved keys; 1,807 translation-format checks, zero failures.
- Source privacy pattern scan and `git diff --check` passed.
- Opt-in recording was exercised on the small regression fixtures: 36 Liquify preview samples, median 0.72 ms, p95 1.94 ms. This is a functional check of recording on small inputs, not a 4K/8K benchmark or input-to-photon measurement.
- The complete CLT app and CLI build passed; strict signature validation passed after installing build 40.25.
- Installed-app review passed for the empty workspace, static document, numeric-entry commit/focus, Typography popover/Escape, Tool Help, Image → Create Animation, and advanced Liquify drawing/undo/cancel. Cancellation was rechecked after fixing stale disabled layer controls.
- A compact 865×561-point window was checked with the text toolbar; main controls and the Typography entry remained visible. The exact 800×520 layout, a complete English UI pass, VoiceOver, and system accessibility-setting changes were not manually exercised. Full Xcode tests were not run locally.
- Only synthetic fixtures were used for editing checks. User recovery files and saved projects were not restored, edited, or removed.
