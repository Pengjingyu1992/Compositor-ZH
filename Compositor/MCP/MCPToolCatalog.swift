import Foundation

/// The legacy tool surface is shared without changing its schemas or ordering.
@MainActor enum MCPToolCatalog {
    static var commandSchema: [String: Any] {
        let kinds = ["addFill", "editFill", "addImage", "addText", "editText", "transform", "opacity", "blendMode", "visibility", "remove", "invert", "fillPixels", "filter", "effects", "reorder", "setMask", "refineEdges", "addPath", "editPath", "textOutlines", "vectorMask"]
        func number(_ lower: Double, _ upper: Double) -> [String: Any] { ["type": "number", "minimum": lower, "maximum": upper] }
        func object(_ properties: [String: Any], _ required: [String]) -> [String: Any] {
            ["type": "object", "properties": properties, "required": required, "additionalProperties": false]
        }
        let halftone = object(["size": number(2, 128), "cyan": number(-180, 180), "magenta": number(-180, 180),
            "yellow": number(-180, 180), "black": number(-180, 180), "strength": number(0, 100),
            "shape": ["type": "string", "enum": ["Round", "Square", "Line"]]], ["size", "cyan", "magenta", "yellow", "black", "strength", "shape"])
        let text = object(["content": ["type": "string", "maxLength": 100000], "fontName": ["type": "string"],
            "fontSize": number(1, 2000), "red": number(0, 1), "green": number(0, 1), "blue": number(0, 1),
            "alignment": ["type": "string", "enum": ["Left", "Center", "Right", "Justified"]], "vertical": ["type": "boolean"],
            "tracking": number(-100, 1000), "leading": number(0, 5000),
            "boxSize": ["type": "array", "items": ["type": "number"], "minItems": 2, "maxItems": 2],
            "colorRuns": ["type": "array"], "fontRuns": ["type": "array"],
            "pathLayout": ["type": "object", "description": "A copy of one VectorPathStyle contour, with offset and reversed."],
            "warp": object(["bend": number(-1,1)], ["bend"])],
            ["content", "fontName", "fontSize", "red", "green", "blue", "alignment", "tracking", "leading"])
        return object([
            "kind": ["type": "string", "enum": kinds], "layerID": ["type": "string", "format": "uuid"],
            "name": ["type": "string"], "opacity": number(0, 1), "visible": ["type": "boolean"],
            "imageData": ["type": "string", "contentEncoding": "base64", "description": "JPEG/PNG/HEIC/TIFF, decoded data at most 16 MiB."],
            "maskData": ["type": "string", "contentEncoding": "base64", "description": "Image luminance times alpha; white reveals, black hides."],
            "clearMask": ["type": "boolean"], "text": text,
            "transform": ["type": "object", "description": "Copy a layer transform from project_state and edit origin, size, rotation or flips."],
            "vector": ["type": "object", "description": "Complete VectorPathStyle from project_state shape.vector or vectorMask; normalized layer coordinates."],
            "fill": ["type": "object", "description": "LayerFillStyle; use compositor-cli example or project_state fill as a complete template."],
            "color": object(["red": number(0, 1), "green": number(0, 1), "blue": number(0, 1), "alpha": number(1, 1)], ["red", "green", "blue", "alpha"]),
            "effects": ["type": "object"], "blendMode": ["type": "string"], "index": ["type": "integer", "minimum": 0],
            "filter": ["type": "string", "description": "FilterKind English name, e.g. Color Halftone, Selective Color, Channel Mixer, Color Lookup."],
            "amount": ["type": "number"], "halftone": halftone,
            "channelMixer": object(["coefficients": ["type": "array", "items": number(-200, 200), "minItems": 12, "maxItems": 12]], ["coefficients"]),
            "selectiveColor": object(["relative": ["type": "boolean"], "adjustments": ["type": "object", "description": "Reds/Yellows/Greens/Cyans/Blues/Magentas/Whites/Neutrals/Blacks -> four CMYK percentages, -100 to 100."]], ["relative", "adjustments"]),
            "lut": object(["cube": ["type": "string"], "strength": number(0, 100), "space": ["type": "string", "enum": ["Encoded sRGB", "Linear sRGB"]]], ["cube", "strength", "space"]),
            "edge": object(["selectSubject": ["type": "boolean"], "feather": number(0, 100), "shift": number(-100, 100),
                "contrast": number(0, 100), "decontaminate": number(0, 100), "createsCopy": ["type": "boolean"],
                "strokes": ["type": "array", "maxItems": 1000, "description": "Each: mode (Refine Edge/Reveal/Hide), diameter, strength 0-1, points [[x,y]] in original layer pixels."]],
                ["selectSubject", "feather", "shift", "contrast", "decontaminate", "createsCopy", "strokes"])
        ], ["kind"])
    }
    static let definitions: [(String, String, [String: Any], [String])] = [
        ("open_project", "Open a local .comp project and return an explicit handle, revision and layer IDs.", ["path": ["type": "string"]], ["path"]),
        ("new_project", "Create an in-memory canvas. No file is written.", ["width": ["type": "integer", "minimum": 1, "maximum": 30000], "height": ["type": "integer", "minimum": 1, "maximum": 30000]], ["width", "height"]),
        ("close_project", "Close an in-memory project without writing it.", ["handle": ["type": "string"]], ["handle"]),
        ("project_state", "Read a project's revision, layers and session locks.", ["handle": ["type": "string"]], ["handle"]),
        ("edit_project", "Run validated commands atomically. A failed batch changes nothing; success is one undo step.", ["handle": ["type": "string"], "documentID": ["type": "string"], "expectedRevision": ["type": "string"], "expectedLockRevision": ["type": "string"], "commands": ["type": "array", "minItems": 1, "maxItems": 500, "items": commandSchema]], ["handle", "documentID", "expectedRevision", "expectedLockRevision", "commands"]),
        ("export_project", "Export a flattened PNG to a new file; existing files are never overwritten.", ["handle": ["type": "string"], "path": ["type": "string"], "expectedRevision": ["type": "string"]], ["handle", "path", "expectedRevision"]),
        ("batch_export_project", "Export multiple sizes or selected layers into a new folder. Options: longSides, format (PNG/JPEG), quality, prefix, individualLayers.", ["handle": ["type": "string"], "path": ["type": "string"], "expectedRevision": ["type": "string"], "options": ["type": "object"], "layerIDs": ["type": "array", "items": ["type": "string"]]], ["handle", "path", "expectedRevision", "options"]),
        ("save_project", "Save to a new .comp package; existing files and the original project are preserved.", ["handle": ["type": "string"], "path": ["type": "string"], "expectedRevision": ["type": "string"]], ["handle", "path", "expectedRevision"]),
        ("undo", "Undo one committed command batch.", ["handle": ["type": "string"], "expectedRevision": ["type": "string"]], ["handle", "expectedRevision"]),
        ("redo", "Redo one command batch.", ["handle": ["type": "string"], "expectedRevision": ["type": "string"]], ["handle", "expectedRevision"]),
        ("set_layer_locks", "Set session-only locks using bits: all=1, content=2, position=4, appearance=8, transparency=16.", ["handle": ["type": "string"], "expectedRevision": ["type": "string"], "layerID": ["type": "string"], "locks": ["type": "integer", "minimum": 0, "maximum": 31]], ["handle", "expectedRevision", "layerID", "locks"])
    ]

    static var listResult: [String: Any] {
        ["tools": definitions.map {
            ["name": $0.0, "description": $0.1,
             "inputSchema": ["type": "object", "properties": $0.2,
                             "required": $0.3, "additionalProperties": false]]
        }]
    }
}
