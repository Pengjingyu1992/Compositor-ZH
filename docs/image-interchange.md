# PNG image interchange on macOS

Compositor and Kaleiform offer a dedicated copy-drag handle. In Compositor it is beside the
Layers count; in Kaleiform it is in Properties when artwork is selected. Drop on the other app's
canvas to insert a new layer or embedded image. The source remains intact and import is undoable.

## Payload version 1

One native pasteboard item offers `public.file-url`, `public.png` and
`org.kaleiform-compositor.image-placement` (the placement JSON). The PNG representations contain the same
complete PNG, never the small cursor preview. An immediate file URL also works with native
receivers that do not consume file promises. No network service or shared app group is required.
Public AppKit API reference: https://developer.apple.com/documentation/appkit/nsdraggingsource

The file is `image.png` in a private temporary directory named
`Kaleiform-Compositor-Transfer-<unique-id>`. Its sibling `transfer.json` has at most 4096 bytes:

```json
{"version":1,"width":1500,"height":1000,"rotation":30,"flipX":false,"flipY":false,"name":"Image"}
```

Width and height describe the unrotated rectangle in document units (one Compositor document
pixel or one Kaleiform point), independently of the PNG's stored pixel dimensions and DPI.
Rotation is clockwise in a top-left coordinate system. Reflection is about the rectangle's centre,
then rotation. The receiving app centres that rectangle on the drop point. Sizes are finite and
within 1..300000; rotation is finite and within +/-360000 degrees. `name` is optional and is
limited to 255 characters by producers. Other apps can consume the PNG without the sidecar.

A sandbox receiver reads the placement from the pasteboard and makes its own temporary copy;
when a file URL has no grant, it reads the complete PNG data representation instead. It does not
need permission to read a neighbouring sidecar outside its container.

The receiver embeds the full bytes before completing import; it never links a document to this
temporary file. Transfer directories remain for at least a day so receivers can finish reading;
a later drag reclaims expired exchange directories. They are not document storage.

## Quality and persistence

A single unmodified PNG with ordinary appearance is passed through byte-for-byte, retaining
alpha (including RGB under zero alpha), 8/16-bit samples, profiles and metadata. Placement changes
remain separate. Pixel edits replace this original. Unsupported transforms or visual effects,
masks and multiple selected objects produce a transparent PNG at full output resolution; the
raster density never drops below that of the selected source images. Exceeding allocation limits
reports an error rather than silently reducing resolution. The clipboard's 4096-pixel preview cap
is not used.

Both editing/rendering pipelines currently use 8-bit data. Original-file retention does not
imply 16-bit or wide-gamut editing. Rendered appearance is bounded by the source renderer's
precision; it is not byte-identical to an earlier original. Backdrop-dependent blend modes
export against transparency and may look different when placed over a different background.

Kaleiform's native document already embeds image blobs. Compositor format 17 additionally keeps
original PNG resources, builds 8-bit sRGB editing proxies on load, and retains original resources
in saves and recovery copies. Versions 1..16 remain readable. Older Compositor builds reject
format 17 explicitly. Previously discarded source detail cannot be reconstructed by dragging.

## Validation

Generated fixtures cover transparent 6000-pixel PNGs at 8 and 16 bits, raw byte equality,
placement/rotation/reflection, save/reopen, source-file removal, undo/redo and rendered opacity.
Native window tests additionally cover both drag directions and cancellation. This document
specifies the intended checks; see [the validation report](image-interchange-validation.md) for completed results.
