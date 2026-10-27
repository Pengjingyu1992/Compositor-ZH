# sharp / libvips source and replacement information

The application uses unmodified sharp 0.35.5 (Apache-2.0) and the platform-specific
`@img/sharp-libvips-*` 1.3.4 shared libraries (LGPL-3.0-or-later and the component
licenses in THIRD-PARTY-NOTICES.md). The application itself remains MIT.

- sharp source: https://github.com/lovell/sharp/tree/v0.35.5
- libvips build recipes and exact dependency versions:
  https://github.com/lovell/sharp-libvips/tree/v1.3.4
- Downloadable build source:
  https://codeload.github.com/lovell/sharp-libvips/tar.gz/refs/tags/v1.3.4
  SHA-256: `a8e96acb479c9bc1a5b7950f8f25aa6c8e1ef3a19755b45cf2f00d506aeaccc0`.

The accompanying build recipes contain the versioned source download URLs and
configuration for the component libraries. The supplied versions file records
their exact versions. Windows additionally uses the matching source and build
configuration from https://github.com/libvips/build-win64-mxe as identified in
build-win.sh.txt. No changes to those libraries are made by this application.

Native shared libraries are distributed outside app.asar, in
`resources/app.asar.unpacked/node_modules/@img/`. You may replace these libraries
with compatible modified versions and debug such modifications. No application
license term restricts the rights granted by the LGPL. Keep the corresponding
license and copyright notices with redistributed copies. The complete GPLv3 and
LGPLv3 texts accompany this file.
