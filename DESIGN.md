# Windows / Linux desktop interface

The user selected **“尽量贴进MacOS版UI风格”** on 2026-10-29 (Asia/Shanghai). This replaces the four exploratory previews. Apply this design to the shared Vue/Electron interface only; the native macOS application, project and release channels stay unchanged.

## Reference and build brief

Primary reference: the repository's native macOS source, particularly `ToolHeaderStyle.swift`, `ProjectTabs.swift`, `LayersPanel.swift` and `ContentView.swift`, rechecked at baseline `36163b2`. The earlier exploration used macOS 40.41 (`f8b1457`); use the current source when those metrics differ. Native appearance colors are semantic AppKit colors, so cross-platform neutral colors approximate them; this is not a claim of screenshot or font identity. The Linux review environment cannot run the native macOS app.

The editor serves drawing and compositing. Within three seconds the user should find the current document, canvas, selected tool and selected layer. Keep creation/import, save/export, project tabs, masks, effects, editing history and the optional AI assistant reachable. Visual changes must not alter document pixels, color management or project history.

Design settings: visual variance 3 (familiar native controls), motion 2 (short feedback), density 7 (compact workbench). The canvas is the main visual focus. Use neutral layers, small rounded controls and one blue interaction accent; avoid tinted green chrome, marketing layouts, decorative gradients and fake macOS window controls.

## Reference values and roles

- Current native source: tool header 42 pt; tool rail 56 pt; tool buttons 36 pt with 7 pt corners. The shared desktop implementation uses a compact 40 px header, 52 px rail and 32 px tools. Keep frequent controls in a stable row; overflow scrolls instead of changing row height.
- Native source: project tabs are 28 px capsule controls, with a compact close target and a modified-state dot. Put document identity in one tab strip, not two repeated headers.
- Current native source: layers panel defaults to 252 pt (202–352 pt range). The shared desktop inspector uses 280 px to fit its property controls. Keep independent layer and property scroll areas with `min-height: 0`; the outer sidebar must not add another scrollbar. Expose a keyboard-accessible inspector toggle.
- Apple design-system reference: neutral light `#f5f5f7`, text `#1d1d1f`, blue action/focus role and rounded primary controls. Translate these roles to the desktop editor; do not import proprietary fonts or website hero styling.
- Use system Chinese fonts and system UI fonts, restrained 400/500/600 weights and tabular numeric fields. Tool controls can be denser than reading copy, following the native editor; notices and explanatory text remain comfortably readable.

## Theme tokens

Define semantic roles for text, secondary text, workspace, panels, controls, borders, selected/hover/pressed states, focus, errors, warnings and success. Default appearance follows the system; offer explicit light and dark choices in local workspace settings. Migrate old settings by adding only the missing appearance preference; do not discard saved grid, ruler or palette preferences.

Do not theme image pixels, mask grayscale, color-picker spectra, proof previews or the transparency checkerboard. Theme changes are local UI preferences, never document edits. Windows/Linux retain their own native title bars, dialogs, application identities and secure key storage.

## Components and behavior

- Toolbar: compact document actions, one project tab strip, zoom/fit, inspector and export. Preserve existing commands, accessible names and revision ownership. Busy controls stay visibly disabled.
- Tool rail: scroll the editing tools; keep navigation and foreground/background color controls reachable in a separate footer. A selected tool uses a blue filled rounded control, not a decorative left stripe.
- Inspector: layers, appearance and property sections have clear neutral grouping. Selected layers use a full background/border. Tab navigation, masks, long layer names and keyboard focus remain functional.
- Use a single segmented group for inspector tabs. Center the layer empty state with a quiet icon, as in the native panel. Keep property labels, control widths and button-row spacing consistent.
- Assistant: start folded for a new profile; respect the user's previously saved folding preference. Settings remain accessible while folded. Expanded content keeps its existing privacy, cancellation and history protections.
- Dialogs: consistent neutral surfaces, 6–10 px corners, modest shadows, native focus/keyboard behavior, clear cancel/apply actions. Errors remain visible with a next action. Preserve the existing preview and editing workspaces.
- Workspace settings use one aligned label/control row at a time, with a semantic grid group; neither language may compress fields below a readable width. Color swatches need a visible keyboard focus outline even though the native color input is transparent.
- File-drop feedback uses the same neutral surface, text and blue accent tokens in both appearances. Prefer the operating system's UI font, with local Chinese fallbacks; bundle no proprietary fonts.

## Verification and boundaries

Run and inspect the actual app at desktop and compact desktop sizes, in light and dark appearance, with Chinese and English labels. Check visible focus, all tools, inspector visibility, long titles, independent scroll areas, assistant expansion/persistence, local appearance persistence and unchanged source projects. Capture a first pass, record concrete findings, then make only the most useful corrections and capture again.

Support `prefers-reduced-motion`; do not add animation to high-frequency painting or keyboard commands. Use existing icons and dependencies. No remote fonts, images, analytics or external design models. Synthetic artwork only.
