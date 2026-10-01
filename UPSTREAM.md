# 源码来源 / Source provenance

The public repository starts with a curated source snapshot. It preserves the upstream license and code attribution; its first commit does not claim original authorship of the editor.

| Project | Source revision | Use |
| --- | --- | --- |
| [Compositor](https://github.com/robbietilton/Compositor) | [`086f1631573ccb2b57644e53b52bf1488fc976aa`](https://github.com/robbietilton/Compositor/commit/086f1631573ccb2b57644e53b52bf1488fc976aa), version 1.4.5 | Native editor, project format, UI, rendering, import, and tests, with localized and modified files. |
| [Pentrado](https://github.com/jtydhr88/pentrado) | [`f172590d7b10e5fd985faf5d3e36edfd4f6a0486`](https://github.com/jtydhr88/pentrado/commit/f172590d7b10e5fd985faf5d3e36edfd4f6a0486) | Architecture and feature references; alignment/distribution geometry adapted from `src/engine/arrange.ts`. |

## Changes since Compositor 1.4.5

- Chinese string catalogs, runtime localization and format-signature validation.
- Persistent Chinese/English settings and a localized app name: **叠绘 / Compositor**.
- New canvas dimension swap; a corrected text-tool icon; localized undo and dynamic labels.
- Edit permission and transaction safeguards; document/revision/instance-bound asynchronous commits.
- Layer alignment/distribution and a paint bucket using the existing fill path.
- Local recovery snapshots, mosaic filtering, and 8-bit RGB PSD export.
- Fixes around effects preservation, resizing, import, and export.
- A new icon, portable CLT build/packaging helpers, a separate bundle identifier, and manual updates from this repository.

The `.comp` format remains version **11** and supports versions **1–11**. The bundle identifier `com.wonderassembly.compositor.zh-Hans` retains compatibility with the Chinese edition's existing settings and recovery storage.

Local machine logs, recovery documents, backups, reference photographs, personal paths, and private operational reports are excluded. The original local checkout and its existing Git history are preserved separately.
