# macOS large-document performance — second batch

Build 40.26 includes the workspace improvements from build 40.25 and changes internal resource management. It does not change the `.comp` format or the Windows implementation.

## Rendering memory

`RenderCache` provides one byte-based LRU for CPU reductions, committed pieces, editable-filter prefixes, Metal surfaces, placed masks, subject masks, full-resolution effects, recent effect previews and color lookups. Its normal limit is RAM / 32, clamped to 64–512 MiB. Warning pressure reduces admission to one quarter; critical pressure drops entries and suspends admission until pressure returns to normal. It also caps metadata at 512 entries.

Entries share an allocation ledger. A texture uses Metal's `allocatedSize`; bitmap images use row stride and height, including reduction padding. A value larger than the budget is returned to the current caller without being retained in the cache. Ordinary cache keys hold weak source references and verify those references before reuse, preventing object-address reuse from returning another image's result. Recent effect previews retain their request inputs and charge them explicitly.

This cap is **not a process-memory limit**. Live document pixels, undo resources, current modal previews, per-frame compositing, Core Image / Metal driver work, workers and encoding allocations are separate. Current effect previews retain the existing per-document preview budget; their bounded recent-history cache participates in the shared LRU. Eviction cannot destroy resources still held by an in-flight command or caller.

## Undo resources

Sparse snapshots charge their shared base, replacement tile backing, thumbnails, materialized contexts and saved filter payloads instead of charging their lazy CGImage as a full contiguous image. Cropped patches keep the root backing identity; possible copied crops are additionally charged conservatively. Filter payload versions share a runtime resource identity across value copies. Changing coverage, a saved displacement field or LUT starts another resource group; these runtime identities are neither serialized nor part of semantic equality.

Each history entry captures its static allocation list once. Budget enforcement builds one reference ledger and decrements it as entries are removed, avoiding a complete rescan after every eviction. Lazy contexts are refreshed during enforcement because exporting can materialize an older snapshot after its history entry was made. The existing 100-entry / 256 MiB defaults remain.

## Committed tiles and GPU ownership

CPU pieces are built only for the visible region. Keys describe the sample region, base placement, mask fill, reduction level and intersecting patch versions, so an unaffected piece can be reused by a new snapshot without retaining its predecessor.

A completed GPU stroke can transfer its surface to an immutable snapshot when its crop fits the stroke grid. Final flush tiles are uploaded first; unchanged tiles are already present. The mutable cache entry is removed, and the stroke's identity changes when it produces a snapshot, so later painting cannot overwrite the committed surface. A crop can use a view into the same retained texture; unsupported geometry or an evicted stroke falls back to assembling a new surface.

Uploaded tile versions are retained as images, rather than remembered only by object address. Stress checks exposed address reuse during final flush; holding the uploaded version prevents an updated tile from being mistaken for an already-uploaded tile. Explicit GPU waits remain instrumented and are retained in this batch; removing them requires separate queue/lifetime evidence.

## Editable filters

Full-resolution prefixes reuse the longest exact match. Source identity, node order, all saved settings, random seeds, selection coverage, LUT data and displacement fields are checked. Editing node k therefore starts after its unchanged prefix; a repeated Preview / Apply can reuse the final output. Cancellation and document-owner checks remain in the commit path. Halftone and noise keep their original pixel grid and seed.

## Reproducible checks

```sh
./scripts/check-memory-performance-clt.zsh --large
./scripts/check-liquify-clt.zsh --shortcuts
./scripts/check-localization.zsh
./scripts/build-clt.zsh
```

The focused suite covers global LRU accounting and pressure, concurrent access, oversized entries, visible-piece reuse, cropped roots and alpha, CPU / Metal handoff, later-stroke immutability, filter prefix invalidation and cancellation, stale document callbacks, materialization after history recording, native save/reopen, and 100 sparse edits with undo/redo at 4K and 8K. Large mode also renders 20 distinct 4K layers and 10 distinct 8K layers through 20 viewport cycles each. These are synthetic CLT scenarios, not input-to-photon timings or a 30-minute GUI stability certification.

## Validation record

- Final large-mode suite: 297 checks, zero failures. The normal-mode repeat passed 156 checks and added four further cases for native filter-recipe reopening, cropped GPU handoff and mask coverage. Counting those additions once gives 301 second-batch checks.
- Existing regression: 103 Liquify, 78 foundational editing and 900 shortcut checks; zero failures.
- 4K and 8K each retained all 100 sparse edits using 5,308,416 history bytes (about 5.1 MiB), excluding live allocations. The previous logical full-image calculation would have charged at least 6,643,777,536 / 26,575,110,144 bytes respectively; those figures describe accounting, not an observed RSS saving.
- Adopted Metal and CPU raster output matched exactly (maximum channel difference 0). Tiled CPU and contiguous output matched including translucent edges; saved/reopened filter recipes rerendered identically. Old filter callbacks could not commit into a replacement document.

| Synthetic scene | Fixture creation + 20 GPU viewport renders | Retained shared cache / normal cap |
| --- | --- | --- |
| 4096×4096, 20 distinct layers | 15,026.5 ms | 155,419,392 / 536,870,912 bytes |
| 8192×8192, 10 distinct layers | 89,622.1 ms | 266,797,824 / 536,870,912 bytes |

These timings include fixture creation and synchronous GPU readback. They are not interactive frame times, a before/after benchmark or a Photoshop comparison. Memory-pressure tests cover warning/critical admission and release; RSS and physical footprint were not separately benchmarked.

- Localization: 1,455 candidates, no missing/untranslated/unresolved keys; 1,807 translation checks, zero failures.
- Complete CLT app and CLI build passed. Source and installed-bundle privacy pattern scan and diff whitespace checks passed. A clean installation copy passed strict signature verification; main executable, CLI and Chinese catalog matched the build bytes. The synced build directory had acquired Finder attributes, so installation used a copy excluding extended attributes.
- Installed version: 1.4.8 (40.26). Native UI checks passed for new canvas, brush dab, undo/redo, zoom, editable-filter preview and Apply. Coordinate dragging was blocked by the automation service's `noWindowsAvailable` error while the application process and accessibility controls remained responsive; continuous dragging was validated by the CLT editor path, not by that GUI action.
- Full Xcode tests and a 30-minute GUI soak were not run. Only newly created synthetic data was edited; user projects and recovery copies were not opened or removed.

## Added files

- `Compositor/Rendering/RenderCache.swift`
- `Compositor/Rendering/FilterPrefixCache.swift`
- `CompositorTests/MemoryPerformanceRegressionTests.swift`
- `scripts/check-memory-performance-clt.zsh`
- This document. The Xcode project uses filesystem-synchronized groups; the new Swift files are included automatically.
