import AppKit
#if !LIVE_MCP_CLT_CHECKS
import Testing
#endif

@MainActor enum LiveMCPRegressionChecks {
    struct Result { var checks = 0; var failures: [String] = [] }
    static func run() async throws -> Result {
        var result = Result()
        func check(_ label: String, _ value: @autoclosure () -> Bool) { result.checks += 1; if !value() { result.failures.append(label) } }
        let root = URL(fileURLWithPath: "/private/tmp/mcp-" + UUID().uuidString.prefix(8))
        let suite = "Compositor.LiveMCP.Tests." + UUID().uuidString
        let defaults = UserDefaults(suiteName: suite)!
        var secrets: [UUID: Data] = [:]
        let workspace = ProjectWorkspace()
        workspace.current.session.createNewProject(width: 1600, height: 900)
        let original = workspace.current
        var approvals = 0
        var approvalHook: (() -> Void)?
        let service = MCPLiveService(workspace: workspace, defaults: defaults, root: root, approval: { _, _ in
            approvals += 1; approvalHook?(); return true
        }, credentials: { id, data, delete in
            if delete { secrets.removeValue(forKey: id) } else if let data { secrets[id] = data }; return secrets[id]
        })
        defer { service.stop(); defaults.removePersistentDomain(forName: suite); try? FileManager.default.removeItem(at: root) }
        let grant = try service.addClient(name: "Synthetic Test Client")
        let clientID = grant.id
        do { _ = try await service.callTool("list_documents", arguments: [:], clientID: clientID); check("disabled server rejects reads", false) }
        catch { check("disabled server rejects reads", true) }
        let blocker = root.appendingPathComponent("host.sock")
        try Data("preserve".utf8).write(to: blocker)
        service.setEnabled(true)
        check("unsafe endpoint is preserved", !service.enabled && (try? Data(contentsOf: blocker)) == Data("preserve".utf8))
        try FileManager.default.removeItem(at: blocker)
        service.setEnabled(true)
        check("socket starts", service.enabled && service.error == nil)
        let permissions = try FileManager.default.attributesOfItem(atPath: service.socketPath)[.posixPermissions] as? NSNumber
        check("socket mode 0600", permissions?.intValue == 0o600)
        let list = try await service.callTool("list_documents", arguments: [:], clientID: clientID)
        check("first private read prompts once", approvals == 1)
        let record = (list["documents"] as! [[String: Any]])[0]
        let handle = record["handle"] as! String
        func get() async throws -> [String: Any] { try await service.callTool("get_document", arguments: ["handle": handle], clientID: clientID) }
        func arguments(_ state: [String: Any], extra: [String: Any] = [:]) -> [String: Any] {
            var value: [String: Any] = ["handle": handle, "expectedRevision": state["revision"]!, "expectedChangeToken": state["changeToken"]!,
                "expectedLockRevision": state["lockRevision"]!, "operationID": service.instance + ":" + UUID().uuidString]
            value.merge(extra) { _, b in b }; return value
        }
        let state = try await get()
        check("live state contains independent tokens", state["changeToken"] is String && state["lockRevision"] is String)
        let second = workspace.addTab(reuseEmpty: false)
        second.session.document = original.session.document
        let filtered = try await service.callTool("list_documents", arguments: [:], clientID: clientID)
        check("unapproved tab is not disclosed", (filtered["documents"] as? [[String: Any]])?.count == 1)
        do { _ = try await service.callTool("get_document", arguments: ["handle": service.instance + ":" + second.id.uuidString + ":" + second.session.document!.id.uuidString], clientID: clientID); check("copied document ID grants no access", false) }
        catch { check("copied document ID grants no access", true) }
        let layerID = original.session.document!.layers[0].id.uuidString
        let edit = arguments(state, extra: ["documentID": state["documentID"]!, "commands": [["kind": "opacity", "layerID": layerID, "opacity": 0.5]]])
        do { _ = try await service.callTool("execute_commands", arguments: edit, clientID: clientID); check("read permission cannot edit", false) }
        catch { check("read permission cannot edit", true) }
        var editable = grant; editable.edit = true; editable.files = true; editable.destructive = true; service.update(editable)
        let beforeUndoCount = original.session.history.undoCount
        let edited = try await service.callTool("execute_commands", arguments: edit, clientID: clientID)
        check("one batch commits one history step", edited["status"] as? String == "changed" && original.session.history.undoCount == beforeUndoCount + 1)
        let duplicate = try await service.callTool("execute_commands", arguments: edit, clientID: clientID)
        check("duplicate operation returns receipt without editing", NSDictionary(dictionary: edited).isEqual(to: duplicate) && original.session.history.undoCount == beforeUndoCount + 1)
        var conflict = edit; conflict["commands"] = [["kind": "opacity", "layerID": layerID, "opacity": 0.2]]
        do { _ = try await service.callTool("execute_commands", arguments: conflict, clientID: clientID); check("operation ID cannot change payload", false) }
        catch { check("operation ID cannot change payload", true) }
        let receipt = try await service.callTool("get_operation_result", arguments: ["operationID": edit["operationID"]!], clientID: clientID)
        check("lost response can be recovered", NSDictionary(dictionary: receipt).isEqual(to: edited))
        original.session.undo()
        check("undo restores history revision", original.session.history.currentRevision.uuidString == state["revision"] as? String)
        check("undo changes monotonic change token", original.session.automationChangeToken.uuidString != state["changeToken"] as? String)
        var stale = edit; stale["operationID"] = service.instance + ":" + UUID().uuidString
        let rejected = try await service.callTool("execute_commands", arguments: stale, clientID: clientID)
        check("undo ABA request is rejected", rejected["status"] as? String == "failed")
        let fresh = try await get()
        let before = original.session.document
        approvalHook = { service.setPaused(true); service.setPaused(false) }
        let destructive = arguments(fresh, extra: ["documentID": fresh["documentID"]!, "commands": [["kind": "remove", "layerID": layerID]]])
        let revoked = try await service.callTool("execute_commands", arguments: destructive, clientID: clientID)
        check("pause/resume during confirmation invalidates commit", revoked["status"] as? String == "failed" && original.session.document == before)
        approvalHook = nil
        let failedBatch = arguments(try await get(), extra: ["documentID": state["documentID"]!, "commands": [["kind": "opacity", "layerID": layerID, "opacity": 0.4], ["kind": "opacity", "layerID": UUID().uuidString, "opacity": 0.2]]])
        let failed = try await service.callTool("execute_commands", arguments: failedBatch, clientID: clientID)
        check("late batch failure rolls back all commands", failed["status"] as? String == "rejected" && original.session.document == before)
        do { _ = try await service.callTool("render_preview", arguments: ["handle": handle, "longSide": 9000], clientID: clientID); check("preview size is bounded by schema", false) }
        catch { check("preview size is bounded by schema", true) }
        let preview = try await service.callTool("render_preview", arguments: ["handle": handle, "longSide": 256], clientID: clientID)
        check("preview renders at bounded output dimensions", preview["width"] as? Int == 256 && preview["height"] as? Int == 144)
        check("preview includes coherent snapshot tokens", (preview["state"] as? [String: Any])?["changeToken"] as? String == original.session.automationChangeToken.uuidString)
        check("preview is encoded PNG", (preview["_image"] as? String).flatMap { Data(base64Encoded: $0) }?.starts(with: [137,80,78,71,13,10,26,10]) == true)
        let folder = root.appendingPathComponent("output", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
        try service.setFolder(folder)
        let sourceURL = original.session.projectURL, wasModified = original.session.isModified
        let save = try await service.callTool("save_document", arguments: arguments(try await get(), extra: ["name": "copy.comp"]), clientID: clientID)
        check("new copy is saved", save["outputName"] as? String == "copy.comp" && FileManager.default.fileExists(atPath: folder.appendingPathComponent("copy.comp/manifest.json").path))
        check("copy does not mark original saved", original.session.projectURL == sourceURL && original.session.isModified == wasModified)
        let loaded = try await ProjectStore.shared.load(from: folder.appendingPathComponent("copy.comp"))
        check("copy can be loaded without format changes", loaded.manifest.documentID == original.session.document!.id && loaded.manifest.width == 1600)
        let staged = ProjectTab(name: "Synthetic Opened Copy")
        let tabCount = workspace.tabs.count
        let opened = await staged.controller.open(folder.appendingPathComponent("copy.comp"))
        check("staging controller opens a saved project", opened)
        check("staged open does not replace an existing document", workspace.tabs.count == tabCount && original.session.document == before)
        check("validated staging tab can be published", workspace.adoptOpenedTab(staged) && workspace.tabs.count == tabCount + 1)
        let overwrite = try await service.callTool("save_document", arguments: arguments(try await get(), extra: ["name": "copy.comp"]), clientID: clientID)
        check("existing project is never overwritten", overwrite["status"] as? String == "failed")
        let traversal = try await service.callTool("export_document", arguments: arguments(try await get(), extra: ["name": "../escape.png"]), clientID: clientID)
        check("directory traversal is rejected", traversal["status"] as? String == "failed" && !FileManager.default.fileExists(atPath: root.appendingPathComponent("escape.png").path))
        let sentinel = root.appendingPathComponent("sentinel"); try Data("unchanged".utf8).write(to: sentinel)
        try FileManager.default.createSymbolicLink(at: folder.appendingPathComponent("link.png"), withDestinationURL: sentinel)
        let symlink = try await service.callTool("export_document", arguments: arguments(try await get(), extra: ["name": "link.png"]), clientID: clientID)
        check("destination symlink cannot overwrite its target", symlink["status"] as? String == "failed" && (try? Data(contentsOf: sentinel)) == Data("unchanged".utf8))
        let exported = try await service.callTool("export_document", arguments: arguments(try await get(), extra: ["name": "new.png"]), clientID: clientID)
        check("PNG export succeeds", exported["outputName"] as? String == "new.png")
        let latest = try await get()
        let badSelection = try await service.callTool("select_layers", arguments: arguments(latest, extra: ["layerIDs": [UUID().uuidString]]), clientID: clientID)
        check("selection cannot target missing layers", badSelection["status"] as? String == "failed")
        let locks = try await service.callTool("set_layer_locks", arguments: arguments(latest, extra: ["layerID": layerID, "locks": 1]), clientID: clientID)
        check("lock changes have a separate revision", locks["lockRevision"] as? String != latest["lockRevision"] as? String)
        let locked = try await get()
        let lockedEdit = try await service.callTool("execute_commands", arguments: arguments(locked, extra: ["documentID": locked["documentID"]!, "commands": [["kind": "opacity", "layerID": layerID, "opacity": 0.3]]]), clientID: clientID)
        check("live edits honor layer locks", lockedEdit["status"] as? String == "rejected")
        service.setPaused(true)
        do { _ = try await get(); check("pause blocks reads", false) } catch { check("pause blocks reads", true) }
        service.setPaused(false)
        let newArguments: [String: Any] = ["width": 48, "height": 32, "operationID": service.instance + ":" + UUID().uuidString]
        _ = try await service.callTool("new_document", arguments: newArguments, clientID: clientID)
        let createdCount = workspace.tabs.count
        workspace.select(original.id); service.authorizeCurrentDocument(for: clientID)
        do { _ = try await service.callTool("new_document", arguments: newArguments, clientID: clientID); check("retry cannot disclose a receipt outside current document scope", false) }
        catch { check("retry cannot disclose a receipt outside current document scope", workspace.tabs.count == createdCount) }
        do { _ = try await service.callTool("get_operation_result", arguments: ["operationID": newArguments["operationID"]!], clientID: clientID); check("receipt queries honor revoked document scope", false) }
        catch { check("receipt queries honor revoked document scope", true) }
        let oldInstance = service.instance
        service.setEnabled(false); service.setEnabled(true)
        check("restarting bridge rotates its epoch", service.enabled && service.instance != oldInstance)
        do { _ = try await get(); check("old handles expire after bridge restart", false) } catch { check("old handles expire after bridge restart", true) }
        let expiredReceipt = try await service.callTool("get_operation_result", arguments: ["operationID": edit["operationID"]!], clientID: clientID)
        check("expired receipts report uncertainty without replay", expiredReceipt["status"] as? String == "unknown" && expiredReceipt["mayHaveCommitted"] as? Bool == true)
        service.revoke(clientID)
        do { _ = try await get(); check("revoke blocks reads", false) } catch { check("revoke blocks reads", true) }
        check("revoke removes credentials", secrets[clientID] == nil && !FileManager.default.fileExists(atPath: root.appendingPathComponent(clientID.uuidString + ".json").path))
        let log = try JSONEncoder().encode(service.activities)
        let logText = String(decoding: log, as: UTF8.self)
        check("activity does not contain paths or command payloads", !logText.contains(root.path) && !logText.contains("\"commands\"") && !logText.contains("secret"))
        service.stop()
        check("host removes its socket on stop", !FileManager.default.fileExists(atPath: service.socketPath))
        return result
    }
}
#if !LIVE_MCP_CLT_CHECKS
@MainActor struct LiveMCPRegressionTests {
    @Test func permissionsTokensReceiptsAndFiles() async throws {
        let result = try await LiveMCPRegressionChecks.run()
        #expect(result.failures.isEmpty, "\(result.failures)")
    }
}
#endif
