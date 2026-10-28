# Portable color kernels

`AdjustPixels.c/.h`, `LensPixels.c/.h`, and `FilterCancellation.h` are unmodified snapshots of the MIT-licensed native renderer at macOS commit `f8b1457`. The native macOS files are not changed. `bridge.c` supplies worker-based cancellation and reports allocation failures instead of silently accepting incomplete renders.

The generated module has no imports, a 512 MiB memory ceiling, no filesystem or network access, and is instantiated inside a terminable worker. The checked-in base64 module lets Windows and Linux use identical code without a native addon or a runtime compiler. `build.json` records source and binary hashes; source/hash checks are part of normal validation.

Rebuild with Clang/LLD 19.1.7, wasi-libc `0.0~git20241209.574b88d-2`, and compiler-rt WASM32 `1:19.1.7-3` (Debian 13 packages):

```sh
node scripts/build-portable-color.mjs
```

For an unpacked toolchain, put its `usr/bin` on `PATH`, set `PORTABLE_COLOR_CC` to `usr/lib/llvm-19/bin/clang`, and set `PORTABLE_COLOR_SYSROOT` to its `usr` directory. `LD_LIBRARY_PATH` may be needed for compiler libraries. Only relative/public provenance is recorded in the generated files. All runtime notices, including musl/WASI libc and LLVM compiler-rt, are in `licenses/portable-color` and must be included in both distributions.
