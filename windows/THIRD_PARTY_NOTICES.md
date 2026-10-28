# Windows third-party notices / Windows 第三方说明

Thank you to **Robbie Tilton / Wonder Assembly LLC**, author of [Compositor](https://github.com/robbietilton/Compositor), and **Terry Jia / jtydhr88**, author of [Pentrado](https://github.com/jtydhr88/pentrado). This community edition brings Chinese localization and practical improvements to their work.

感谢 Compositor 作者 Robbie Tilton 与 Pentrado 作者 Terry Jia 及贡献者。本项目的目标是中文本地化和实际完善，不代表两位作者的官方 Windows 产品。

- **Compositor**: MIT; copyright 2026 Wonder Assembly LLC. The project format and application icon are reused from this edition. The Swift native application is not included in the Windows executable. See `licenses/Compositor-LICENSE.txt` in the installed resources.
- **Pentrado 0.1.1**: MIT; copyright 2026 Terry Jia. The Windows renderer imports `pentrado/engine` for WebGL compositing. It uses a separate Vue editing interface, not Pentrado's complete editor UI. Arrangement and symmetry contracts inform the shared editing helpers. The adapter chooses sRGB blending and compositing without modifying Pentrado's global defaults. See `licenses/pentrado-LICENSE`.
- **Vue and its dependencies**: the interface uses Vue. Versions and their license texts are generated from the pinned dependency tree into `resources/licenses/DEPENDENCIES.json` and accompanying files.
- **Typr.js**: MIT; copyright 2016 Photopea, vendored by Pentrado. Its full license is retained in `licenses/Typr-LICENSE.txt`, including when tree shaking removes its font code from this renderer. Text editing uses installed fonts and stores text parameters plus saved pixels; editable outlines are stored as native path geometry; font files are not embedded.
- **Electron 44.5.1**: MIT, Electron contributors. The distribution includes Electron's `LICENSE` and Chromium's `LICENSES.chromium.html`. These files must stay alongside the application. Chromium and bundled components have their own notices in that HTML file.
- **ag-psd 31.0.2**: MIT, Agamnentzar and contributors; PSD parsing and writing. PNG conversion uses **pngjs 7.0.0**, MIT, its authors and contributors. Their dependencies (`pako`, `base64-js`) and license texts are included in `resources/licenses/`.
- **Build tools**: electron-builder, Vite, TypeScript, vue-tsc, and Playwright are build/CI dependencies, not additional application features. `reka-ui` and `vue-i18n` are not used by this interface.
- **gifenc 1.0.3**: MIT, Matt DesLauriers and contributors; per-frame GIF palette quantization and animated GIF encoding. **omggif 1.0.10**: MIT, Dean McNamee; GIF frame decoding. Full license texts are included in `resources/licenses/`.
- **Ghostscript**: an optional, separately installed PostScript interpreter for general EPS import. It is not bundled or linked; no Ghostscript executable, library, fonts or source are included in these packages. See its own distribution and license. Compositor's raster EPS codec is original code.

There is no telemetry, hosted editing service, account, automatic updater, or bundled API credential. When you invoke the optional AI assistant, your prompt and layer metadata are sent to the endpoint you configure; image pixels and project files are not sent. Your own API key is stored with Electron `safeStorage` encryption when available and sent as bearer authorization. The reference photograph for the icon palette is not distributed. Runtime libraries are compiled into the renderer; dependency notices may also cover code removed by tree shaking. Source maps and CI/private project fixtures are excluded from application packages.

- **sharp 0.35.5**: Apache-2.0; ICC-aware image conversion via Little CMS and libvips. Platform-specific shared libvips libraries are LGPL-3.0-or-later with additional component licenses. See `resources/licenses/sharp-libvips/` for license texts, upstream source/build references and library replacement rights. Native libraries remain outside app.asar.

- **fontkit 2.0.4**: MIT (Brotli decoder portions Apache-2.0), Devon Govett and contributors; local installed-font shaping and vector outlines. Its pinned dependencies and notices are included in `resources/licenses/`. System font files are read locally and are not included in projects or distribution packages.

## Portable Camera Raw kernels

The Windows/Linux renderer includes an import-free WebAssembly build of this project's MIT-licensed macOS `f8b1457` color/lens kernels. Source, source/binary SHA-256 and reproducible Clang/LLD 19.1.7 build instructions are retained in `native/portable-color`. The native macOS source is unchanged. Runtime allocation/math code from wasi-libc `574b88d` (including musl notices) and LLVM compiler-rt 19.1.7 is covered by the full inventory and license texts in `licenses/portable-color`, copied into every installation package. The module has no filesystem/network imports and does not bundle the compiler.
