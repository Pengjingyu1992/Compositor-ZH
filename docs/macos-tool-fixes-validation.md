# macOS tool fixes — build 40.23

## Findings and changes

- Eyedropper help fell through to Zoom help. The tool switch now explicitly covers every tool; Eyedropper describes click/drag color sampling in both languages.
- The toolbar relied on SF Symbol accessibility names, which exposed Zoom Out as Zoom In. The two controls are separate toolbar items with explicit localized labels.
- Recovery was correctly refusing a 33rd document, but the generic storage-full message obscured the document-count limit. Count-limit failures now report the limit separately from byte capacity. The banner offers recovery management and retry; the management sheet shows the count. Closing it retries failed checkpoints across open tabs.
- A Liquify regression assumed every project uses the highest readable format. It now requires the correct v14 format for saved Liquify and an unchanged version after reopening. The highest readable version remains v15 for channel-screen halftone.
- PSD fixture byte writers are explicitly nonisolated, matching the nonisolated fixture callers and removing compiler isolation warnings.

Recovery capacity policy is unchanged: 32 document identities / 4 GiB; no automatic deletion. The isolated regression store verifies the count limit and retry behavior. No project format change is introduced by these fixes.

## Automated validation

| Check | Result |
|---|---|
| Editable filters and recovery, including quota/retry regression | 104 checks, 0 failures |
| Liquify | 89 checks, 0 failures |
| First-batch editing rules | 78 checks, 0 failures |
| Keyboard shortcuts | 900 checks, 0 failures |
| Total directed runtime checks | 1,171 checks, 0 failures |
| Source localization candidates | 1,408 candidates, no missing/untranslated/unresolved keys |
| Catalog translations and format signatures | 1,752 translations, 0 failures |

The quota regression uses an isolated temporary store. It verifies refusal without deleting existing copies, a distinct count-limit error, retrying an inactive tab after one slot is freed, preserving the latest committed state and unsaved marker, leaving a remaining failure visible, then retrying the second tab after another slot is freed, including after its error banner was dismissed. Repeated retry creates no extra copies. These checks use the Command Line Tools harness; the full Xcode test target was not run.

## Installed application validation

The installed app is 1.4.8 (40.23), with unchanged bundle identity and sandbox entitlements. Both application and CLI executable hashes match the verified build; strict code-signature verification passed. Previous app builds were moved to recoverable Trash.

On a disposable 512 × 512 canvas:

- Selecting Eyedropper by its I shortcut displays the correct Chinese sampling instruction.
- Accessibility exposes distinct Zoom In / Zoom Out names. Their clicks changed zoom from 249.6% to 300%, then 200%, following the existing zoom stops.
- After the recovery delay, the banner correctly reports the 32-document limit and exposes review/retry actions.
- Review opens the recovery sheet and shows 32 copies / limit 32. Closing it and pressing Retry keeps the warning visible while capacity is still full.
- The temporary canvas was closed without saving; the app was left on its empty welcome page.

Existing recovery data was left untouched during installed UI validation. Positive retry after freeing capacity, including a dismissed error banner and inactive tabs, is covered by the isolated regression above. No real recovery copy was deleted.
