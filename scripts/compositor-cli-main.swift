import AppKit
import CryptoKit

/// Kept outside the synchronized app source directory: this is the helper's entry point.
@main struct CompositorCLI {
    @MainActor static func main() async {
        _ = NSApplication.shared
        do {
            let arguments = Array(CommandLine.arguments.dropFirst())
            if arguments.first == "mcp" {
                if arguments == ["mcp", "--live"] {
                    throw CLIError.message("Live MCP is not available in this build. Use standalone MCP until the authorized live Host is ready.")
                }
                guard arguments == ["mcp"] || arguments == ["mcp", "--standalone"] else {
                    throw CLIError.message("Usage: compositor-cli mcp [--standalone]")
                }
                try await PosterMCPServer().run(); return
            }
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

@MainActor final class PosterMCPServer: MCPDocumentHost {
    private var projects: [String: EditorSession] = [:]
    private var tasks: [String: Task<Void, Never>] = [:]
    func run() async throws {
        for try await line in FileHandle.standardInput.bytes.lines {
            guard line.utf8.count <= MCPProtocol.maximumMessageBytes, let data = line.data(using: .utf8),
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
                result = MCPProtocol.legacyInitialization(parameters)
            case "ping": result = [:]
            case "tools/list":
                result = MCPToolCatalog.listResult
            case "tools/call":
                do {
                    let value = try await MCPToolRouter.call(parameters["name"] as? String ?? "", arguments: parameters["arguments"] as? [String: Any] ?? [:], host: self)
                    result = try MCPProtocol.legacyToolResult(value)
                } catch {
                    result = MCPProtocol.legacyToolError(error)
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
    func executeMCPTool(_ name: String, arguments: [String: Any]) async throws -> [String: Any] {
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
