import AppKit
import CryptoKit

/// Kept outside the synchronized app source directory: this is the helper's entry point.
@main struct CompositorCLI {
    @MainActor static func main() async {
        _ = NSApplication.shared
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "mcp" { try await PosterMCPServer().run(); return }
            if arguments.first == "example" {
                let command = PosterCommand(kind: .addFill, fill: LayerFillStyle(kind: .linear))
                let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
                FileHandle.standardOutput.write(try encoder.encode([command])); print(""); return
            }
            guard arguments.count >= 2 else {
                throw CLIError.message("Usage: compositor-cli inspect INPUT.comp | preview INPUT.comp OUTPUT.png | batch INPUT.comp COMMANDS.json NEW.comp SOURCE_SHA256 | batch-export INPUT.comp OPTIONS.json FOLDER | mcp | example")
            }
            let input = URL(fileURLWithPath: arguments[1]).standardizedFileURL
            let before = try packageFingerprint(input)
            let snapshot = try await ProjectStore.shared.load(from: input)
            guard before == (try packageFingerprint(input)) else { throw CLIError.message("Source changed while opening.") }
            let session = EditorSession(); session.installProject(snapshot, from: input)
            switch arguments[0] {
            case "inspect":
                var state = session.automationState(); state["sourceFingerprint"] = before
                try printJSON(state)
            case "preview":
                guard arguments.count == 3 else { throw CLIError.message("Expected an output PNG path.") }
                let output = URL(fileURLWithPath: arguments[2])
                try await ImageExporter.shared.write(ImageExporter.shared.pngData(snapshot), to: output, mustNotExist: true)
                try printJSON(["output": output.path])
            case "batch-export":
                guard arguments.count == 4 else { throw CLIError.message("Expected options JSON and an existing output folder.") }
                let options = try JSONDecoder().decode(BatchExportOptions.self, from: boundedData(URL(fileURLWithPath: arguments[2]), maximum: 65536))
                let output = try await BatchImageExporter.shared.export(snapshot, selected: session.selectedLayerIDs,
                    name: input.deletingPathExtension().lastPathComponent, options: options, folder: URL(fileURLWithPath: arguments[3]))
                try printJSON(["output": output.path])
            case "batch":
                guard arguments.count == 5, arguments[4] == before else { throw CLIError.message("The source SHA256 must match inspect output.") }
                let data = try boundedData(URL(fileURLWithPath: arguments[2]), maximum: 32 * 1024 * 1024)
                let commands = try JSONDecoder().decode([PosterCommand].self, from: data)
                let outcome = await session.executePosterBatch(PosterBatchRequest(documentID: snapshot.manifest.documentID, expectedRevision: session.history.currentRevision, commands: commands))
                guard ["changed", "unchanged"].contains(outcome.status), let result = session.projectSnapshot() else { throw CLIError.message(outcome.message ?? outcome.errorCode ?? outcome.status) }
                guard before == (try packageFingerprint(input)) else { throw CLIError.message("Source changed before export.") }
                let output = URL(fileURLWithPath: arguments[3]).standardizedFileURL
                try await ProjectStore.shared.save(result, to: output, quickLook: ImageExporter.shared.quickLookImages(result), mustNotExist: true)
                try printJSON(["status": outcome.status, "output": output.path, "state": session.automationState()])
            default: throw CLIError.message("Unknown command.")
            }
        } catch {
            if let data = try? JSONSerialization.data(withJSONObject: ["error": error.localizedDescription]) {
                FileHandle.standardError.write(data); FileHandle.standardError.write(Data([10]))
            }
            exit(1)
        }
    }
    static func boundedData(_ url: URL, maximum: Int) throws -> Data {
        let values = try url.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
        guard values.isRegularFile == true, values.isSymbolicLink != true, (values.fileSize ?? Int.max) <= maximum else { throw CLIError.message("Invalid or oversized input file.") }
        let data = try Data(contentsOf: url)
        guard data.count <= maximum else { throw CLIError.message("Input changed while reading.") }; return data
    }
    static func packageFingerprint(_ url: URL) throws -> String {
        let root = url.resolvingSymlinksInPath()
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]) else { throw ProjectError.invalid }
        var files: [URL] = []
        for case let file as URL in enumerator {
            guard files.count < 30_100, try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else { throw ProjectError.tooLarge }
            files.append(file)
        }
        files.sort { $0.path < $1.path }
        var hash = SHA256(), total = 0
        for file in files {
            let values = try file.resourceValues(forKeys: [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey])
            guard values.isSymbolicLink != true else { throw ProjectError.invalid }
            if values.isRegularFile != true { continue }
            let size = values.fileSize ?? Int.max
            guard size <= 512 * 1024 * 1024, total <= 2 * 1024 * 1024 * 1024 - size else { throw ProjectError.tooLarge }
            total += size
            hash.update(data: Data(file.path.dropFirst(root.path.count).utf8)); hash.update(data: Data([0]))
            hash.update(data: Data(size.description.utf8)); hash.update(data: Data([0]))
            let handle = try FileHandle(forReadingFrom: file)
            do {
                while let part = try handle.read(upToCount: 1024 * 1024), !part.isEmpty { hash.update(data: part) }
                try handle.close()
            } catch { try? handle.close(); throw error }
        }
        return hash.finalize().map { String(format: "%02x", $0) }.joined()
    }
    static func printJSON(_ value: Any) throws {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
        FileHandle.standardOutput.write(data); FileHandle.standardOutput.write(Data([10]))
    }
}

enum CLIError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(value) = self { value } else { nil } }
}

@MainActor final class PosterMCPServer {
    private static var commandSchema: [String: Any] {
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
    private var projects: [String: EditorSession] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    private let definitions: [(String, String, [String: Any], [String])] = [
        ("open_project", "Open a local .comp project and return an explicit handle, revision and layer IDs.", ["path": ["type": "string"]], ["path"]),
        ("new_project", "Create an in-memory canvas. No file is written.", ["width": ["type": "integer", "minimum": 1, "maximum": 30000], "height": ["type": "integer", "minimum": 1, "maximum": 30000]], ["width", "height"]),
        ("close_project", "Close an in-memory project without writing it.", ["handle": ["type": "string"]], ["handle"]),
        ("project_state", "Read a project's revision, layers and session locks.", ["handle": ["type": "string"]], ["handle"]),
        ("edit_project", "Run validated commands atomically. A failed batch changes nothing; success is one undo step.", ["handle": ["type": "string"], "documentID": ["type": "string"], "expectedRevision": ["type": "string"], "expectedLockRevision": ["type": "string"], "commands": ["type": "array", "minItems": 1, "maxItems": 500, "items": PosterMCPServer.commandSchema]], ["handle", "documentID", "expectedRevision", "expectedLockRevision", "commands"]),
        ("export_project", "Export a flattened PNG to a new file; existing files are never overwritten.", ["handle": ["type": "string"], "path": ["type": "string"], "expectedRevision": ["type": "string"]], ["handle", "path", "expectedRevision"]),
        ("batch_export_project", "Export multiple sizes or selected layers into a new folder. Options: longSides, format (PNG/JPEG), quality, prefix, individualLayers.", ["handle": ["type": "string"], "path": ["type": "string"], "expectedRevision": ["type": "string"], "options": ["type": "object"], "layerIDs": ["type": "array", "items": ["type": "string"]]], ["handle", "path", "expectedRevision", "options"]),
        ("save_project", "Save to a new .comp package; existing files and the original project are preserved.", ["handle": ["type": "string"], "path": ["type": "string"], "expectedRevision": ["type": "string"]], ["handle", "path", "expectedRevision"]),
        ("undo", "Undo one committed command batch.", ["handle": ["type": "string"], "expectedRevision": ["type": "string"]], ["handle", "expectedRevision"]),
        ("redo", "Redo one command batch.", ["handle": ["type": "string"], "expectedRevision": ["type": "string"]], ["handle", "expectedRevision"]),
        ("set_layer_locks", "Set session-only locks using bits: all=1, content=2, position=4, appearance=8, transparency=16.", ["handle": ["type": "string"], "expectedRevision": ["type": "string"], "layerID": ["type": "string"], "locks": ["type": "integer", "minimum": 0, "maximum": 31]], ["handle", "expectedRevision", "layerID", "locks"])
    ]
    func run() async throws {
        for try await line in FileHandle.standardInput.bytes.lines {
            guard line.utf8.count <= 32 * 1024 * 1024, let data = line.data(using: .utf8),
                  let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                try CompositorCLI.printJSON(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]); continue
            }
            if request["method"] as? String == "notifications/cancelled", let parameters = request["params"] as? [String: Any], let id = parameters["requestId"] { tasks[String(describing: id)]?.cancel(); continue }
            guard let id = request["id"] else { continue }
            let key = String(describing: id)
            guard tasks[key] == nil else {
                try CompositorCLI.printJSON(["jsonrpc": "2.0", "id": id, "error": ["code": -32600, "message": "Duplicate request ID"]]); continue
            }
            tasks[key] = Task { await respond(request); tasks.removeValue(forKey: key) }
        }
        for task in tasks.values { await task.value }
    }
    private func respond(_ request: [String: Any]) async {
        let id = request["id"] ?? NSNull()
        do {
            let parameters = request["params"] as? [String: Any] ?? [:]
            let result: [String: Any]
            switch request["method"] as? String {
            case "initialize":
                let supported = ["2025-11-25", "2025-06-18", "2024-11-05"]
                let wanted = parameters["protocolVersion"] as? String ?? ""
                result = ["protocolVersion": supported.contains(wanted) ? wanted : supported[0], "capabilities": ["tools": ["listChanged": false]], "serverInfo": ["name": "Compositor", "version": "1.4.5"]]
            case "ping": result = [:]
            case "tools/list":
                result = ["tools": definitions.map { ["name": $0.0, "description": $0.1, "inputSchema": ["type": "object", "properties": $0.2, "required": $0.3, "additionalProperties": false]] }]
            case "tools/call":
                do {
                    let value = try await call(parameters["name"] as? String ?? "", arguments: parameters["arguments"] as? [String: Any] ?? [:])
                    let data = try JSONSerialization.data(withJSONObject: value, options: [.sortedKeys])
                    result = ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]], "isError": ["failed", "rejected"].contains(value["status"] as? String ?? "")]
                } catch {
                    result = ["content": [["type": "text", "text": error.localizedDescription]], "isError": true]
                }
            default:
                try CompositorCLI.printJSON(["jsonrpc": "2.0", "id": id, "error": ["code": -32601, "message": "Method not found"]]); return
            }
            try CompositorCLI.printJSON(["jsonrpc": "2.0", "id": id, "result": result])
        } catch { try? CompositorCLI.printJSON(["jsonrpc": "2.0", "id": id, "error": ["code": -32603, "message": error.localizedDescription]]) }
    }
    private func integer(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(), number.doubleValue.isFinite,
              number.doubleValue.rounded() == number.doubleValue, abs(number.doubleValue) <= Double(Int32.max) else { return nil }
        return number.intValue
    }
    private func call(_ name: String, arguments: [String: Any]) async throws -> [String: Any] {
        guard let definition = definitions.first(where: { $0.0 == name }), definition.3.allSatisfy({ arguments[$0] != nil }), Set(arguments.keys).isSubset(of: Set(definition.2.keys)) else { throw CLIError.message("Invalid tool arguments.") }
        if name == "open_project" || name == "new_project" {
            guard projects.count < 8 else { throw CLIError.message("At most eight projects can be open.") }
            let session = EditorSession()
            if name == "open_project" {
                guard let path = arguments["path"] as? String else { throw CLIError.message("Expected path.") }
                let url = URL(fileURLWithPath: path), before = try CompositorCLI.packageFingerprint(url)
                let snapshot = try await ProjectStore.shared.load(from: url)
                guard before == (try CompositorCLI.packageFingerprint(url)) else { throw CLIError.message("Source changed while opening.") }
                session.installProject(snapshot, from: url)
            } else {
                guard let width = integer(arguments["width"]), let height = integer(arguments["height"]),
                      (1...DocumentLimits.maxSide).contains(width), (1...DocumentLimits.maxSide).contains(height) else { throw ProjectError.invalid }
                session.createNewProject(width: width, height: height)
            }
            let handle = UUID().uuidString; projects[handle] = session
            return ["handle": handle, "state": session.automationState()]
        }
        guard let handle = arguments["handle"] as? String, let session = projects[handle] else { throw CLIError.message("Unknown project handle.") }
        if name == "project_state" { return session.automationState() }
        if name == "close_project" {
            guard !session.isProjectBusy else { throw CLIError.message("Project is busy.") }
            projects.removeValue(forKey: handle); return ["closed": handle]
        }
        guard arguments["expectedRevision"] as? String == session.history.currentRevision.uuidString, !session.isProjectBusy else { throw CLIError.message("Stale revision or busy project.") }
        if name == "edit_project" {
            var fields = arguments; fields.removeValue(forKey: "handle")
            let data = try JSONSerialization.data(withJSONObject: fields)
            let request = try JSONDecoder().decode(PosterBatchRequest.self, from: data)
            let result = await session.executePosterBatch(request)
            return ["status": result.status, "errorCode": result.errorCode ?? "", "message": result.message ?? "", "state": session.automationState()]
        }
        if name == "undo" { session.undo(); return session.automationState() }
        if name == "redo" { session.redo(); return session.automationState() }
        if name == "set_layer_locks" {
            guard session.canEditLayers, let id = (arguments["layerID"] as? String).flatMap(UUID.init(uuidString:)),
                  session.document?.layers.contains(where: { $0.id == id }) == true, let bits = integer(arguments["locks"]), (0...31).contains(bits) else { throw ProjectError.invalid }
            session.lockDocumentID = session.document?.id; session.layerLocks[id] = bits == 0 ? nil : LayerLocks(rawValue: bits)
            return session.automationState()
        }
        guard let path = arguments["path"] as? String, let snapshot = session.projectSnapshot(), let owner = session.beginOwnedEdit() else { throw CLIError.message("Invalid export request.") }
        defer { session.releaseEdit(owner) }
        let url = URL(fileURLWithPath: path)
        if name == "batch_export_project" {
            guard let fields = arguments["options"] as? [String: Any] else { throw ProjectError.invalid }
            let options = try JSONDecoder().decode(BatchExportOptions.self, from: JSONSerialization.data(withJSONObject: fields))
            let rawIDs = arguments["layerIDs"] as? [String] ?? []
            let ids = Set(rawIDs.compactMap(UUID.init(uuidString:)))
            guard ids.count == rawIDs.count, ids.allSatisfy({ id in snapshot.manifest.layers.contains { $0.id == id } }) else { throw ProjectError.invalid }
            let result = try await BatchImageExporter.shared.export(snapshot, selected: ids, name: "Project", options: options, folder: url)
            return ["output": result.path, "state": session.automationState()]
        }
        if name == "save_project" {
            guard url.pathExtension.lowercased() == "comp" else { throw ProjectError.invalid }
            try await ProjectStore.shared.save(snapshot, to: url, quickLook: ImageExporter.shared.quickLookImages(snapshot), mustNotExist: true)
        } else {
            guard url.pathExtension.lowercased() == "png" else { throw ProjectError.invalid }
            try await ImageExporter.shared.write(ImageExporter.shared.pngData(snapshot), to: url, mustNotExist: true)
        }
        return ["output": path, "state": session.automationState()]
    }
}
