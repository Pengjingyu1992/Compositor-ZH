import Foundation

@MainActor enum MCPLiveCatalog {
    typealias Definition = (String, String, [String: Any], [String])
    static let aliases = ["project_state": "get_document", "edit_project": "execute_commands", "open_project": "open_document",
        "new_project": "new_document", "save_project": "save_document", "export_project": "export_document",
        "batch_export_project": "batch_export_document", "close_project": "close_document"]
    static let reads: Set<String> = ["list_documents", "get_document", "render_preview", "get_capabilities", "get_operation_result"]
    static let files: Set<String> = ["open_document", "save_document", "export_document", "batch_export_document"]
    static var definitions: [Definition] {
        let string: [String: Any] = ["type": "string"]
        let handle: [String: Any] = ["handle": string]
        let guarded: [String: Any] = ["handle": string, "expectedRevision": string, "expectedChangeToken": string, "expectedLockRevision": string, "operationID": string]
        let guards = ["handle", "expectedRevision", "expectedChangeToken", "expectedLockRevision", "operationID"]
        func add(_ extra: [String: Any]) -> [String: Any] { guarded.merging(extra) { _, new in new } }
        var tools: [Definition] = [
            ("list_documents", "List only authorized open document instances. Handles expire when tabs close or the app restarts.", [:], []),
            ("get_document", "Read document, layers, selection, revision, changeToken and lockRevision. Fetch fresh tokens before editing.", handle, ["handle"]),
            ("render_preview", "Return a coherent PNG snapshot and its tokens. longSide defaults to 1024 (256–2048).", handle.merging(["longSide": ["type": "integer", "minimum": 256, "maximum": 2048]]) { _, v in v }, ["handle"]),
            ("get_capabilities", "Read limits, command schemas and the operationID prefix. No document contents.", [:], []),
            ("get_operation_result", "Read this client's receipt after a lost response. Unknown or expired receipts never authorize a retry with a new ID.", ["operationID": string], ["operationID"]),
            ("execute_commands", "Apply 1–500 commands atomically as one undo step. operationID must start with the server operationPrefix and end with a new UUID. Reuse the identical ID and arguments after a timeout. Deletion, replacing masks and rasterization require a separate confirmation.", add(["commands": ["type": "array", "minItems": 1, "maxItems": 500, "items": MCPToolCatalog.commandSchema], "documentID": string]), guards + ["commands", "documentID"]),
            ("undo", "Undo the latest document edit; may affect a human edit and always requires confirmation.", guarded, guards),
            ("redo", "Redo the latest document edit; always requires confirmation.", guarded, guards),
            ("set_layer_locks", "Change session locks (0–31). Does not change project format.", add(["layerID": string, "locks": ["type": "integer", "minimum": 0, "maximum": 31]]), guards + ["layerID", "locks"]),
            ("select_layers", "Select explicit existing layer IDs without editing pixels.", add(["layerIDs": ["type": "array", "items": string, "maxItems": 10000]]), guards + ["layerIDs"]),
            ("set_view", "Set zoom 0.01–64 or fit the document. Does not change pixels.", add(["zoom": ["type": "number", "minimum": 0.01, "maximum": 64], "fit": ["type": "boolean"]]), guards),
            ("new_document", "Create a new visible canvas and authorize it for this client. No file is written.", ["width": ["type": "integer", "minimum": 1, "maximum": 30000], "height": ["type": "integer", "minimum": 1, "maximum": 30000], "operationID": string], ["width", "height", "operationID"]),
            ("open_document", "Ask the user to choose a .comp project. A supplied path only seeds the picker; it grants no access.", ["path": string, "operationID": string], ["operationID"]),
            ("save_document", "Save a new .comp copy inside the approved output folder. Never overwrites or clears the original unsaved state.", add(["name": string]), guards + ["name"]),
            ("export_document", "Export a PNG into the approved output folder. Supply a filename, not a path; no overwrite.", add(["name": string]), guards + ["name"]),
            ("batch_export_document", "Export a new batch folder inside the approved output folder.", add(["options": ["type": "object"], "layerIDs": ["type": "array", "items": string]]), guards + ["options"]),
            ("close_document", "Close the specified tab after per-request confirmation, including unsaved-discard confirmation.", guarded, guards)
        ]
        for (alias, name) in aliases.sorted(by: { $0.key < $1.key }) {
            if let tool = tools.first(where: { $0.0 == name }) { tools.append((alias, "Live alias of \(name). Uses the live tokens and file restrictions. " + tool.1, tool.2, tool.3)) }
        }
        return tools
    }
    static var tools: [[String: Any]] {
        definitions.map { name, description, properties, required in
            let canonical = aliases[name] ?? name
            return ["name": name, "description": description,
                "inputSchema": ["type": "object", "properties": properties, "required": required, "additionalProperties": false],
                "annotations": ["readOnlyHint": reads.contains(canonical), "destructiveHint": !reads.contains(canonical),
                                "idempotentHint": true, "openWorldHint": false]]
        }
    }
    static func displayName(_ tool: String) -> String {
        switch aliases[tool] ?? tool {
        case "list_documents", "resources/list": L10n.text("List Documents")
        case "get_document", "resources/read": L10n.text("Read Document")
        case "render_preview": L10n.text("Render Preview")
        case "get_capabilities": L10n.text("Read Capabilities")
        case "get_operation_result": L10n.text("Read Operation Receipt")
        case "execute_commands": L10n.text("Edit Command Batch")
        case "undo": L10n.text("Undo")
        case "redo": L10n.text("Redo")
        case "set_layer_locks": L10n.text("Layer Locks")
        case "select_layers": L10n.text("Select Layers")
        case "set_view": L10n.text("Set View")
        case "new_document": L10n.text("New Canvas")
        case "open_document": L10n.text("Open Project")
        case "save_document": L10n.text("Save Copy")
        case "export_document": L10n.text("Export")
        case "batch_export_document": L10n.text("Batch Export")
        case "close_document": L10n.text("Close Document")
        default: tool
        }
    }
    static func displayStatus(_ status: String) -> String {
        switch status {
        case "changed": L10n.text("Changed")
        case "unchanged": L10n.text("Unchanged")
        case "failed": L10n.text("Failed")
        case "rejected": L10n.text("Rejected")
        case "complete": L10n.text("Completed")
        default: status
        }
    }
    static func validate(_ name: String, arguments: [String: Any]) throws {
        guard let tool = definitions.first(where: { $0.0 == name }), tool.3.allSatisfy({ arguments[$0] != nil }),
              arguments.keys.allSatisfy({ tool.2[$0] != nil }) else { throw MCPBridgeError.message("Invalid tool arguments.") }
        for (key, value) in arguments {
            guard let schema = tool.2[key] as? [String: Any] else { continue }
            switch schema["type"] as? String {
            case "string": guard value is String else { throw ProjectError.invalid }
            case "array": guard value is [Any] else { throw ProjectError.invalid }
            case "object": guard value is [String: Any] else { throw ProjectError.invalid }
            case "boolean": guard let number = value as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else { throw ProjectError.invalid }
            case "integer", "number":
                guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
                      schema["type"] as? String != "integer" || number.doubleValue.rounded() == number.doubleValue,
                      number.doubleValue >= ((schema["minimum"] as? NSNumber)?.doubleValue ?? -.infinity), number.doubleValue <= ((schema["maximum"] as? NSNumber)?.doubleValue ?? .infinity) else { throw ProjectError.invalid }
            default: break
            }
        }
    }
}
