# Brush rendering and 4K benchmark

The brush now sweeps a continuous round tip along the smoothed pointer path with a Metal compute kernel. Each changed 256 × 256 tile is processed once per update. Permanent coverage and the provisional tail have separate buffers, so replacing a tail cannot leave old pixels behind. Soft coverage accumulates by integrating paint deposition over distance travelled, equivalent to source-over tips at 2.5% diameter spacing. This blends self-crossings and corners smoothly and is independent of pointer-event count. The opacity setting caps the entire accumulated stroke. Hard tips retain their antialiased silhouette; the software fallback uses 2.5% soft / 1.5% hard tip spacing.

Mouse-up installs an immutable `RasterSnapshot` and records the undo entry synchronously. Snapshots share unchanged tiles and flatten their replacement lists using a spatial index. Bounds are found in changed tiles with a small optimized C routine, instead of scanning every document pixel in unoptimized Swift. The canvas and subsequent strokes read the tiles directly. A contiguous CGImage is created lazily when export or an image-processing operation needs its bytes. Masks use the same snapshot handoff, including white coverage in newly expanded areas.

The Metal pipeline is compiled once by the system compiler and warmed when selecting Brush. This does not require Xcode's optional Metal toolchain. Pixel kernels remain optimized in Debug; Swift code retains its normal Debug optimization settings.

## Measured on September 12, 2026

4000 × 4000 document, 800 px brush, 0% hardness, 100% opacity. Two strokes of 120 pointer updates each, 40 document pixels per update, in a native 1000 × 1000 NSWindow at fit zoom. Times include the model update and `CanvasView.synchronizeDisplay()` / `displayIfNeeded()`. Mouse-up includes flush, commit, history, and the following display. These are synchronous CPU timings, not an input-to-photon measurement or a Photoshop benchmark.

| Debug, blank paint layer | Before | After |
| --- | ---: | ---: |
| Median pointer update | 6.54 ms | 2.64 ms |
| 95th percentile update | 11.98 ms | 3.70 ms |
| Mouse-up, first stroke | 1058 ms | 8.71 ms |
| Mouse-up, second stroke | 1002 ms | 8.14 ms |

On an existing opaque 4K layer, the new 800 px brush measured 2.80 ms median / 5.38 ms p95, with 5.2–6.2 ms mouse-up. The 40 px brush measured 0.36–0.47 ms median, with 1.3–4.8 ms mouse-up. Timing varies with hardware, viewport, layer stack, and system load; no resolution-independent frame-rate guarantee is implied.

Release also built and passed the benchmark. Its 800 px blank-layer median was 2.81 ms and mouse-up was 9.6–11.0 ms (the original Release mouse-up was 87–111 ms). The opaque-layer run measured 4.35 ms median and 7.4–15.9 ms mouse-up; this variation reinforces using measured ranges rather than promising a fixed frame rate.

The final Debug unit run passed **171 tests in 25 suites**. Logs for this change are `/tmp/compositor-brush-final-tests.log`, `/tmp/compositor-brush-new-debug.log`, `/tmp/compositor-brush-new-release.log`, and `/tmp/compositor-brush-baseline-debug.log`.

## Reproduce

Run performance tests alone, so other main-actor tests do not contend with the benchmark. `TEST_RUNNER_` forwards the environment variable into the Xcode test host.

```sh
TEST_RUNNER_BRUSH_BENCHMARK=1 xcodebuild \
  -project Compositor.xcodeproj -scheme Compositor -configuration Debug \
  -derivedDataPath /tmp/CompositorBrush -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO ENABLE_DEBUG_DYLIB=NO \
  -parallel-testing-enabled NO \
  -only-testing:CompositorTests/BrushPerformanceTests test
```

The benchmark logs `BRUSH BENCH` lines and exports `/tmp/compositor-brush-benchmark.png` for visual inspection. It exercises both blank and opaque layers. The exported example contains both benchmark passes.

Functional coverage includes continuous soft coverage at 800 px, tile boundaries, curve/tail replacement, opacity, selections, transformed layers, immediate subsequent strokes, mask painting/expansion, immutable snapshots, display/export agreement, undo/redo, save/reopen, and the software fallback. Snapshots are verified not to materialize during commit, display, or the next stroke.

## Self-intersection correction

The initial continuous-tip implementation took the maximum falloff at each pixel. That removed stamp ridges, but the meeting point of two feathered edges formed a sharp crease. Soft tips now integrate optical density along each curve segment, then convert the accumulated density to coverage. Permanent density is stored in floating-point tile buffers; provisional tails remain separate and are replaced, never double-counted. Hard tips keep their solid silhouette. The existing opacity cap and immediate snapshot commits are unchanged.

Crossing tests compare the joined stroke against source-over coverage, verify the opacity cap, repeated flushes, the software fallback, and equivalent output at sparse/dense sampling for 12, 120, and 520 px tips. The matching 520 px / 4K example is exported to `/tmp/compositor-brush-crossing.png` by `BrushIntersectionTests/exportCrossingExample` with `TEST_RUNNER_BRUSH_BENCHMARK=1`.

With this correction, the 800 px / 4K Debug benchmark measured 3.08–3.12 ms median update and 6.3–9.7 ms mouse-up across blank and opaque layers. Log: `/tmp/compositor-intersection-bench.log`.

The post-correction full Debug suite passed **175 tests in 26 suites** (`/tmp/compositor-intersection-full.log`).
