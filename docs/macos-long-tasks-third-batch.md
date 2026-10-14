# macOS long tasks — third batch

Build 40.27 includes the previous two batches and improves GIF and recovery tasks. The normal `.comp` format and recovery-record version remain unchanged.

## GIF export

Export As previews only the currently displayed frame, with the same full-size resizing, binary-alpha threshold and ImageIO palette used by final export. The dialog states that this is a current-frame preview. It does not encode the entire animation just to draw a preview.

Calculate Size is a separate cancellable operation with a frame counter. Export starts that operation when necessary; if the same frozen source and settings have already been encoded, it reuses the complete bytes and does not encode again. At most one prepared frame and one complete GIF are kept per dialog. Settings changes, cancellation and dismissal invalidate the job identity; late results and progress cannot replace a newer job. Completion is guarded against duplicate clicks / Return callbacks.

The representative frame's encoded block can be reused at its actual frame position, including its duration. Source selection follows the snapshot's displayed frame or active-layer frame; the export sheet receives the exact snapshot used to render its initial raster. Dimensions, transparency, matte, palette, delays, loop count and disposal behavior retain their existing meaning. GIF keeps its 16 MP / frame, 500 frames, 64 MP total and 64 MiB encoded limits.

## GIF import

The parser reads directly from the immutable input buffer. It retains ranges for compressed patches instead of making a second input array plus copies of every isolated patch. Only the patch currently being decoded is assembled for ImageIO. Large extension blocks can be skipped without collecting their contents.

File reads are chunked. Cancellation checks cover block parsing, LZW validation, frame compositing, disposal and export's alpha/encoding boundaries. Native ImageIO calls finish their current call before cancellation can be observed; cancellation is cooperative, not an interruption of those native routines.

Cancel Import cancels the active batch and its unfinished files. Completed files remain in the batch's undo entry; an unfinished GIF is never inserted frame by frame. Sandbox grants and completion continuations are released even on cancellation. Decode results are checked against the target document and history revision before insertion.

## Recovery I/O and integrity

Previously every warm checkpoint reread every resource for SHA-256 and recursively enumerated all other packages for quota. Recovery now retains inode/size/mode plus nanosecond modification/change stamps. Unchanged indexed files undergo metadata checks; changed files must match their original digest before reuse. Same-size edits with restored mtime are caught by ctime. Cold packages still pass the full project loader. Symlink and package-boundary checks remain.

Hardlink creation and removal change ctime; the writer validates data identity across its own link operation and refreshes stamps after exchanging / cleaning up the old package. It validates staged resources before commit. Capacity inventories track known files and directories, including empty resource directories. File growth updates capacity; a directory change causes a rescan, so new external files are counted. The ledger is keyed by package filename inside its store, avoiding URL spelling / trailing-slash differences.

These checks still inspect filesystem metadata. They do not bypass external corruption detection or make quota checking constant time. Changed layers are still encoded as complete PNGs; sparse recovery journals and tile-based recovery persistence are a separate future change.

Write statistics expose encoded images, reused resources, bytes written, logical bytes read, rehashed / checked files, package rescans and elapsed checkpoint time. Cold read counts estimate validated package size and can include unreferenced files; they are not physical disk I/O. Opt-in performance recording adds GIF preview/encoding/decoding, main-actor recovery snapshot capture and background recovery writing. Labels contain no document names or paths.

## Recovery protection UI

The status bar shield opens Recovery Protection: last successful completion time, whether that checkpoint matches the current committed revision, pending changes, writing state and errors. The coordinator updates protection only after a successful package write and only for the same document. It never calls `markSaved`; in-progress gestures remain outside a committed checkpoint. Recovery Copies lists full date and time.

## Checks

```sh
./scripts/check-long-tasks-clt.zsh --large
./scripts/check-editable-recovery-clt.zsh --crash
./scripts/check-memory-performance-clt.zsh
./scripts/check-localization.zsh
./scripts/build-clt.zsh
```

The first suite covers frame offsets / disposal 2 and 3, timing and loops, preview / final palettes, encoded-byte reuse, cancellation, 100-frame export, warm recovery reuse, same-size corruption, capacity changes, old-copy preservation, and protection revision semantics. Existing editable/recovery checks include the interrupted-writer scenario. Full Xcode execution and long GUI stress remain separate from these CLT checks.

## Validation record

Validated on 2026-10-14 with Command Line Tools. Build 1.4.8 / 40.27 is installed locally.

| Check | Result |
| --- | --- |
| Long-task suite, including 100-frame export | 105 checks, 0 failures |
| Editable filters / recovery, including interrupted writer | 107 checks, 0 failures |
| Liquify regressions | 103 checks, 0 failures |
| First-batch regressions | 78 checks, 0 failures |
| Shortcut regressions | 900 checks, 0 failures |
| Memory / rendering regressions | 156 checks, 0 failures |
| Total above | 1,449 checks, 0 failures |

The recovery suite forcibly terminates a writer and verifies that the checkpoint remains complete and readable. The long-task suite also injects `ENOSPC` at the commit boundary; it verifies preservation of the previous copy and removal of the failed staging package. This is an injected disk-full error, not a test with a physically full disk.

A separate quiet run of the synthetic 100-frame, 800 × 600 fixture measured 5.58 ms for one current-frame preview and 694.07 ms for the complete animation encoding (114,133 bytes). A warm recovery checkpoint encoded no images, rehashed no resources, read 201 logical bytes, wrote 201 bytes and took 3.26 ms. These are single harness observations with different preview / full-export workloads; they are not end-to-end UI latency, an application memory comparison, or a measured before/after improvement.

The installed UI was exercised with a generated 320 × 240, eight-frame project. GIF opened with the current-frame preview and an uncalculated file size; Calculate Size displayed the completed size, and Export wrote a readable GIF. ImageIO confirmed eight frames and delays of 20, 40, 60, 80, 100, 120, 140 and 160 ms. The raw Netscape repeat count is 3 (ImageIO reports four total plays). After changing one frame duration, Recovery Protection showed the successful write time and that the current committed revision was protected. The synthetic document was then closed without saving. No user document or preexisting recovery copy was opened or modified.

The app and CLI built successfully. The clean installed bundle passed strict code-signature verification, and its executables and Chinese catalog matched the built files. Source / installed-bundle privacy scanning checked 495 files with 0 findings. Localization checked 1,469 candidate keys (0 missing, untranslated or unresolved) and 1,822 translations (0 failures). Whitespace checks passed. Windows files are unchanged.

Full Xcode tests, a long GUI stress run and real disk-exhaustion behavior remain unverified. Native ImageIO work observes cancellation after its current call returns. Changed image resources still require complete PNG encoding for recovery.

## New files in this batch

- `Compositor/IO/GIFExportWorkspace.swift`
- `Compositor/IO/RecoveryFileInventory.swift`
- `Compositor/UI/RecoveryProtectionView.swift`
- `CompositorTests/LongTaskRegressionTests.swift`
- `scripts/check-long-tasks-clt.zsh`
- `docs/macos-long-tasks-third-batch.md`

The existing filesystem-synchronized Xcode groups include these Swift files automatically. The first- and second-batch changes remain included in this local build.
