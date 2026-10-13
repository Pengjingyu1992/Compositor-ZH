# Linux edition

The Linux application shares the Vue/Electron editor in `../windows`; do not duplicate its editor or change the native macOS application for Linux work. Keep the existing Windows application identity, data directory, packages and release channel intact.

Build from `../windows` with `npm ci`, `npm run package:linux` (AppImage, Deb and tar.gz, x64), or `npm run package:linux:dir` for a fast unpacked build. Outputs live in `linux/release`, separately from Windows artifacts. Node 24 is used in CI. Linux releases use `linux-v*` tags and remain prereleases until accepted on real desktops; never replace the macOS `/releases/latest` release.

Run the shared type check, unit tests, independent PSD reader and Playwright smoke suite. Run headless GUI checks in Xvfb. Only set `COMPOSITOR_SMOKE_NO_SANDBOX=1` when the test container cannot support Chromium's sandbox; do not disable the sandbox in packaged application configuration or recommend doing so on normal desktops. Test with synthetic projects and isolated settings directories.

Linux API keys require a real Secret Service/KWallet backend. Never accept Chromium's `basic_text` fallback as secure storage. Include Compositor, Pentrado, Vue, Typr, Electron, Chromium and codec licenses in all packages. Keep Ghostscript optional and unbundled.
