# 源码来源 / Source provenance

The public repository starts with a curated source snapshot. It preserves the upstream license and code attribution; its first commit does not claim original authorship of the editor.

| Project | Source revision | Use |
| --- | --- | --- |
| [Compositor](https://github.com/robbietilton/Compositor) | [`086f1631573ccb2b57644e53b52bf1488fc976aa`](https://github.com/robbietilton/Compositor/commit/086f1631573ccb2b57644e53b52bf1488fc976aa), version 1.4.5 | Native editor, project format, UI, rendering, import, and tests, with localized and modified files. |
| Compositor 1.4.6–1.4.8 | [`22c7b8d5b23bb1e27a5746912061b23757c4f554`](https://github.com/robbietilton/Compositor/commit/22c7b8d5b23bb1e27a5746912061b23757c4f554) | Subsequent native-editor changes adapted to this edition; excludes upstream Sparkle, appcast, signing settings and release configuration. |
| [Lens-lzy](https://github.com/Lens-lzy) contributions to Compositor | [#241](https://github.com/robbietilton/Compositor/pull/241) `36ced5db0a6725ef26dcd8f31ddaa19320b42ada`; [#244](https://github.com/robbietilton/Compositor/pull/244) `572409993e1bc3ab954705e278c341a938a0ce94`; [#245](https://github.com/robbietilton/Compositor/pull/245) `dadb90ad01d462dd210b17bba27b1679fe4be163` | Custom crop ratios, WebP import, CMYK proofing and TIFF export, adapted and localized while the upstream PRs are unmerged. |
| [Pentrado](https://github.com/jtydhr88/pentrado) | [`f172590d7b10e5fd985faf5d3e36edfd4f6a0486`](https://github.com/jtydhr88/pentrado/commit/f172590d7b10e5fd985faf5d3e36edfd4f6a0486) | Architecture and feature references; alignment/distribution geometry adapted from `src/engine/arrange.ts`. |

## Changes since Compositor 1.4.5

- Chinese string catalogs, runtime localization and format-signature validation.
- Persistent Chinese/English settings and a localized app name: **叠绘 / Compositor**.
- New canvas dimension swap; a corrected text-tool icon; localized undo and dynamic labels.
- Edit permission and transaction safeguards; document/revision/instance-bound asynchronous commits.
- Layer alignment/distribution and a paint bucket using the existing fill path; layer locks, local recovery snapshots, and mosaic filtering.
- A liquify workspace and handoff to a shared advanced liquify filter.
- Editable solid/gradient/pattern fill layers, gradient and pattern overlays, basic inner bevel, manual edge refinement, and color decontamination.
- Color halftone, selective color, channel mixer, and `.cube` LUT filters; Chinese vertical text and justified alignment; multi-size PNG/JPEG export.
- Transactional edit commands, a standalone CLI and an independent stdio MCP server.
- 8-bit RGB PSD export and fixes around effects preservation, resizing, import, and export.
- Editable pen paths, text outlines, path/arc text, vector masks and supported editable PSD records.
- Upstream 1.4.8 RAW/noise/tone and translucent-effect fixes, export previews/PDF, Navigator, command search, canvas-only view, last-filter repeat and standalone Scanlines.
- WebP import, custom crop ratios, print units/backgrounds, CMYK conversion preview and ICC-tagged CMYK TIFF export. Print settings are session-only; documents remain sRGB.
- A new icon, portable CLT build/packaging helpers, a separate bundle identifier, and manual updates from this repository.

The macOS app reads `.comp` versions **1–13** and saves version **13**. Windows-native new documents remain version **11**; the Windows project bridge accepts v12/v13, preserves their metadata and resource bytes, and restricts edits that cannot represent their visual properties. The bundle identifier `com.wonderassembly.compositor.zh-Hans` retains compatibility with the Chinese edition's existing settings and recovery storage. This upstream integration changes the macOS edition; Windows app code and releases are separate.

Local machine logs, recovery documents, backups, reference photographs, personal paths, and private operational reports are excluded. The original local checkout and its existing Git history are preserved separately.
