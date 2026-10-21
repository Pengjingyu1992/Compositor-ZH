# PNG interchange validation — 2026-10-21

Local macOS builds only. No public release or repository push was performed.

## Canvas-drag correction — 2026-10-22

The later user recording showed an ordinary canvas move going beyond Compositor's 1920-pixel
canvas; no native copy-drag had been started. The earlier manual report below does not establish
acceptance for this direct-canvas gesture. Dedicated handles and direct canvas moves are distinct
entry points.

The correction converts an ordinary move into a native copy-drag only after crossing the source
window's outer frame. It rolls back the move first and clears the internal drag state. Kaleiform
also converts an existing panel-art drag when it subsequently crosses the window boundary, while
retaining its existing in-window panel behavior. Native tracking retains current drag events and
releases the UI pointer when a native session completes or is cancelled.

Completed for this correction:

- Compositor transfer suite: **80 checks, 0 failures**, including real CanvasView mouse-event
  routing through a substituted native starter, repeated transitions, Option-copy rollback,
  unchanged source layer count/history, ordinary in-window move/undo, and existing 8/16-bit PNG
  transfer/persistence checks. Added checks cover receiving-window activation, canvas keyboard
  focus, immediate Delete, and deletion undo/redo with original PNG byte equality. This starter substitution does not test a native destination drop.
- Compositor broader regression: **78 editor checks + 900 shortcut checks, 0 failures**.
- Kaleiform: **all 7 CI gates passed; 4,791 tests passed, 0 failed, 5 ignored**. New canvas tests
  cover a direct window crossing, crossing after a panel-art transition, one native start per
  gesture, unchanged source/selection/history, repeated gestures, and recovery after a simulated
  native start failure. Existing native completion tests cover pointer release.
- Local installed builds: Compositor **1.4.8 (40.40)** and Kaleiform
  **0.7.0-kaleiform.15 / png-canvas-drag-local**. Strict signatures passed; installed executable
  hashes match their signed build artifacts. Both prior app bundles are retained in a separate
  local backup directory for this correction.
- Actual in-window Compositor move/undo was verified. A canvas crossing generated the complete
  original transparent PNG with byte equality and left the source position unchanged. In installed
  40.40, Delete removed a previously received layer and Undo restored it; saving retained both
  received green PNG resources byte-for-byte. Immediate Delete after a fresh cross-window drop,
  without an intervening activation click, remains a real-mouse acceptance item.
- Automated cross-window attempts have **not demonstrated a destination insertion**. The user
  subsequently reported insertion into Compositor with a Delete-key problem. Its saved QA document
  contains two imported green PNG resources byte-identical to the Kaleiform source. This confirms
  retained incoming data, while full real-mouse acceptance of both direct-canvas directions remains
  pending. No completed bidirectional acceptance is claimed for this correction.
- Changed-source privacy scans found no pattern matches. Compositor's source/bundle scan found
  no matches. Kaleiform binaries contain no literal personal build-home path; broad token-like
  strings and the generic remapped build path are byte-identical to the prior installed app.

Compositor additionally activates its receiving window and requests canvas keyboard focus after a
successful provider drop. Delete and undo/redo are checked on the imported layer. Failed or unchanged
provider operations do not request this focus transfer. The CLT runner uses an AppKit application
event loop; the key-window assertion requires an active GUI host and reports a skip if macOS denies
standalone CLI activation. The final local run executed all 80 checks with no skips or failures.

No repository push or public release was performed.

## Earlier dedicated-handle checks

- Compositor image-transfer suite: **54 checks, 0 failures**. Generated 6000-pixel transparent 8/16-bit PNGs retain exact original bytes through transfer, format-17 save/reopen, recovery and undo/redo. Tests also cover separate rotation/reflection/placement, pixel-edit invalidation, ancestor appearance, transparent rendering without a 4096-pixel cap, data-only pasteboard input, metadata and an unreadable-file-URL fallback.
- Compositor targeted broader regression: **1,356 checks, 0 failures** (editable recovery/filter, liquify, first-batch UI, shortcuts, poster and path/PSD checks). This ran before the final native drag-handle adjustment; the final transfer suite and application build were rerun afterwards.
- Kaleiform `RUST_TEST_THREADS=1 cargo xtask ci`: **all 7 gates passed**, **4,790 tests passed**, 0 failed, 5 ignored. Gates: fmt, clippy, tests, assets/clean-room, brands, layers and wasm. The serial run avoids an unrelated asynchronous dense-preview test timing out under parallel load.
- Kaleiform source-gesture test checks that pressing/moving/releasing its dedicated handle starts exactly one native transfer. The drop test verifies full-byte embedding independent of the source temporary directory.
- Cross-project fixture: Kaleiform's engine consumed the 16-bit PNG generated by Compositor and returned identical bytes.
- Native applications opened with the dedicated handles visible. Both apps generated exchange files identical to the synthetic 800×600 PNG. The GUI-saved native documents retained the same PNG bytes.
- **Manual end-to-end acceptance:** the user tested both applications with a real mouse and confirmed “两个方向都成功”. The automated computer-use drag action could initiate sources but did not demonstrate destination drops, so that confirmation supplies the actual cross-window acceptance evidence.
- Both app bundles built and passed strict code-signature verification. At installation, previous app bundles were moved to Trash. The final audit could no longer find that Trash folder; no remaining rollback bundle is claimed.
- Privacy scan: Compositor source/bundle had no pattern findings. Kaleiform's seven broad-pattern hits were reviewed: existing synthetic test paths, a pre-existing WASM fixture, a remapped generic build path, and concatenated language/CSS names matching the token regex. No personal build-home path or credential was identified.

## Quality boundary

Unmodified ordinary single PNGs preserve the complete original file, including alpha, 16-bit samples and embedded profiles. Scale, rotation and reflection remain placement metadata. Edited/effected/masked or multi-object selections render their current appearance on transparency at source density, within the applications' existing 8-bit rendering precision and allocation limits. Backdrop-dependent blending may change against another background. This does not add 16-bit/wide-gamut editing.

Compositor writes format 17 when original PNG resources are present; older builds cannot open those documents. Existing versions 1–16 remain readable, and documents without retained originals keep their previous minimum format.
