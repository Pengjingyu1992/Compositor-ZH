# PSD export

File > Export PSD writes an original implementation of Adobe's PSD version-1 format: 8-bit RGB, raw channel compression, merged transparency, Unicode layer names, resolution and an embedded sRGB ICC profile. [Adobe file format specification](https://www.adobe.com/devnet-apps/photoshop/fileformatashtml/) defines the records and channel layout.

Layered export retains pixel layers, folders, visibility, 8-bit opacity, the 24 supported blend modes, adjacent clipping stacks and layer masks. Transforms are rendered into upright pixel grids over their rounded rotated bounds, including positions outside the canvas. Mask coordinates and enablement are retained; independently moved masks may acquire different link behavior in other editors. Names retain Unicode through `luni` records.

Live text and primitive shapes export as pixels, with a conversion notice. They are not editable text or vectors in the PSD. Adjustments, visible layer effects and nonadjacent clipping relationships require flattened export in this first version. The dialog disables unsupported layered export and offers one rendered composite layer. The source document stays editable and is never marked saved by PSD export.

Limits: 512 MiB encoded output, 10,000 raw layer records (folder dividers count), and the document's existing side/surface limits. Empty canvases produce a transparent composite layer. Encoding and rendering precede atomic destination replacement, so an encoding failure leaves an existing destination intact.

Validation combines Compositor's PSDReader with ag-psd 31.0.2 in raw ImageData mode: layer and folder order, Unicode names, blend keys, opacity, visibility, bounds, disabled masks, grayscale mask samples, original pixels and every merged/flattened pixel. A real editor open remains a separate interoperability check. These checks do not certify all Photoshop versions or identical blend rendering in every editor.
