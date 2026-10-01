# 第三方说明 / Third-party notices

## Compositor

- Author: **Robbie Tilton**; copyright **2026 Wonder Assembly LLC**.
- Source: <https://github.com/robbietilton/Compositor>
- License: **MIT**, retained verbatim in [LICENSE](LICENSE) and bundled as `Compositor-LICENSE.txt`.
- This repository contains a modified version of the native editor. The Chinese localization and improvements do not change ownership of the original work.

## Pentrado

- Author: **Terry Jia / jtydhr88**; copyright **2026 Terry Jia**.
- Source: <https://github.com/jtydhr88/pentrado>
- License: **MIT**, retained verbatim in [Pentrado-LICENSE.txt](Compositor/Resources/Pentrado-LICENSE.txt) and included in the app.
- `Compositor/Document/LayerArrange.swift` adapts geometry from `src/engine/arrange.ts`. Pentrado also informed the feature comparison and implementation planning. This app does not bundle the Pentrado web editor or its full dependency tree.

## Other materials

- PSD serialization is an original implementation following Adobe's public file-format specification. `ag-psd` was used as an independent local validation reader and is not distributed in the app.
- The app icon was generated for this edition and is included as an asset. The personal reference photograph used for its color palette is not distributed.
- Apple's frameworks and system SDKs are supplied by macOS/Xcode and are not included in the source package.
- This edition uses manual release downloads and does not distribute Sparkle or use the upstream update feed.

感谢 Compositor 和 Pentrado 的作者及贡献者。这个项目的目的，是做好中文本地化与实际改进，并在适合时将通用修复反馈给上游。

Thank you to the authors and contributors of Compositor and Pentrado. This project's purpose is Chinese localization and practical improvements, with general fixes shared upstream when appropriate.
