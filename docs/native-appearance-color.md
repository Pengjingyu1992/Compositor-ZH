# Native appearance and display colour — local 40.41

Editor chrome now uses AppKit semantic colours (`windowBackgroundColor`,
`controlBackgroundColor`, `underPageBackgroundColor`) in the selected system/light/dark
appearance. CPU and GPU canvas surrounds use the same resolved under-page colour. Native
SwiftUI controls, SF Symbols, system typography, accent colour, toolbar materials and floating
inspectors remain in use. This aligns with Kaleiform's macOS semantic-colour theme while
retaining each editor's tool layout.

The canvas already tags Metal output as sRGB and imports through ImageIO/Core Image with
colour matching into its sRGB editing space. Its display pipeline and image resources were not
retinted. The companion Kaleiform correction explicitly tags Metal output as sRGB and reads
embedded RGB/gray PNG/JPEG profiles.

Reference: <https://developer.apple.com/documentation/quartzcore/cametallayer/colorspace>.

Original PNG retention, native copy-drag, received-layer keyboard focus, deletion and undo remain
unchanged. Existing editing remains 8-bit sRGB; unmodified retained PNGs preserve their complete
original bit depth/profile through interchange. No user artwork or system ICC/font file is added
to the repository. Local validation results are recorded separately when complete.

## Local validation (2026-10-22)

- CLT application build compiled 40.41. The file-provider copy added signing metadata;
  clean staging in a temporary directory fixed packaging, and the staged/installed app
  passed strict deep signature verification with identical executable hashes.
- Theme/filter polish: 38 checks passed; editor regression: 78 passed.
- Image interchange: 79 checks passed, no failures; one receiving-window activation
  assertion was skipped because macOS denied activation to the standalone CLI host.
- In the installed application, Delete removed the imported image (one layer to zero),
  and Command-Z restored its selection and original 886-pixel dimensions.
- The actual canvas screenshot, converted using its embedded monitor profile to sRGB,
  had mean absolute channel error 1.112/255 against an independent CoreGraphics
  reference over low-gradient image pixels. Interpolation/decoder differences remain.
- Source/bundle privacy-pattern scan: 462 files, zero findings. The previous installed
  app was verified and retained outside the checkout before replacement.
- Xcode is not installed here; the Xcode test target/full suite was not run. The CLT
  checks above and actual installed-window validation are the local evidence.
