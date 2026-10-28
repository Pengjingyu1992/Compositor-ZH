# Portable color runtime notices

Compositor color/lens kernels: macOS `f8b1457`, under the repository's MIT license (Wonder Assembly LLC, 2026). See `Compositor-MIT.txt` and `native/portable-color` for exact sources and reproducible module metadata.

wasi-libc snapshot `574b88d` (Debian `0.0~git20241209.574b88d-2`): https://github.com/WebAssembly/wasi-libc/tree/574b88d. The module links allocation and mathematical routines from its musl-based libc. The complete upstream/Debian copyright inventory and embedded MIT/BSD/ISC/Sun notices are retained in `wasi-libc-copyright.txt`; CC0 and Apache full texts are included separately. Source/header inventories also name code not linked into this module.

LLVM compiler-rt builtins 19.1.7 (Debian `1:19.1.7-3`): https://github.com/llvm/llvm-project/tree/llvmorg-19.1.7/compiler-rt. Apache-2.0 with LLVM Exceptions, retained in `compiler-rt-copyright.txt` and `Apache-2.0.txt`. The compiler and linker themselves are build tools and are not distributed.
