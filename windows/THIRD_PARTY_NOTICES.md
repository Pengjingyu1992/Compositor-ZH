# Windows third-party notices / Windows 第三方说明

Thank you to **Robbie Tilton / Wonder Assembly LLC**, author of [Compositor](https://github.com/robbietilton/Compositor), and **Terry Jia / jtydhr88**, author of [Pentrado](https://github.com/jtydhr88/pentrado). This community edition brings Chinese localization and practical improvements to their work.

感谢 Compositor 作者 Robbie Tilton 与 Pentrado 作者 Terry Jia 及贡献者。本项目的目标是中文本地化和实际完善，不代表两位作者的官方 Windows 产品。

- **Compositor**: MIT; copyright 2026 Wonder Assembly LLC. The project format and application icon are reused from this edition. The Swift native application is not included in the Windows executable. See `licenses/Compositor-LICENSE.txt` in the installed resources.
- **Pentrado 0.1.1**: MIT; copyright 2026 Terry Jia. The Windows renderer imports `pentrado/engine` for WebGL compositing. It uses a separate, read-only Vue interface, not Pentrado's complete editor UI. The adapter chooses sRGB blending and compositing without modifying Pentrado's global defaults. See `licenses/pentrado-LICENSE`.
- **Vue and its dependencies**: the interface uses Vue. Versions and their license texts are generated from the pinned dependency tree into `resources/licenses/DEPENDENCIES.json` and accompanying files.
- **Typr.js**: MIT; copyright 2016 Photopea, vendored by Pentrado. Its full license is retained in `licenses/Typr-LICENSE.txt`, including when tree shaking removes its font code from this read-only renderer. This version displays saved text pixels, not editable outlines.
- **Electron 44.5.1**: MIT, Electron contributors. The distribution includes Electron's `LICENSE` and Chromium's `LICENSES.chromium.html`. These files must stay alongside the application. Chromium and bundled components have their own notices in that HTML file.
- **Build tools**: electron-builder, Vite, TypeScript, vue-tsc, and Playwright are build/CI dependencies, not additional application features. No `ag-psd`, `reka-ui`, or `vue-i18n` dependency is used by this Windows viewer.

There is no telemetry, hosted editing service, updater, account, or API key. The reference photograph for the icon palette is not distributed. Runtime libraries are compiled into the renderer; dependency notices may also cover code removed by tree shaking. Source maps and CI/private project fixtures are excluded from application packages.
