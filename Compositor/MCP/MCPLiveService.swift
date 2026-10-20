import AppKit
import Observation
import UniformTypeIdentifiers
import CryptoKit
import Darwin

nonisolated struct MCPClientGrant: Codable, Identifiable {
    let id: UUID
    var name: String
    var read = true
    var edit = false
    var files = false
    var destructive = false
    var paused = false
}
nonisolated struct MCPActivity: Identifiable, Codable {
    let id: UUID
    let date: Date
    let client: String
    let tool: String
    let status: String
    let tabID: UUID?
    let undoRevision: UUID?
    let changeToken: UUID?
}

/// Owns authorization and live document instances; transport and self-reported clientInfo cannot grant access.
@MainActor @Observable final class MCPLiveService {
    let workspace: ProjectWorkspace
    private(set) var instance = UUID().uuidString
    private(set) var enabled = false
    private(set) var paused = false
    private(set) var clients: [MCPClientGrant] = []
    private(set) var activities: [MCPActivity] = []
    private(set) var connected: [UUID: UUID] = [:]
    var error: String?
    var selectedClientID: UUID?
    private(set) var folder: URL?
    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored let root: URL
    @ObservationIgnored private var authorizationRevision = UUID()
    @ObservationIgnored private var server: MCPUnixServer?
    private var authorized: [UUID: Set<UUID>] = [:]
    @ObservationIgnored private var peers: [UUID: MCPUnixConnection] = [:]
    @ObservationIgnored private var legacyVersions: [UUID: String] = [:]
    @ObservationIgnored private var tasks: [UUID: [String: Task<Void, Never>]] = [:]
    @ObservationIgnored private var legacySubscriptions: [UUID: Set<String>] = [:]
    @ObservationIgnored private var watchers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored private var pendingApproval = false
    @ObservationIgnored private var receipts: [String: [String: Any]] = [:]
    @ObservationIgnored private var receiptOrder: [String] = []
    @ObservationIgnored private var seen: [String: Data] = [:]
    @ObservationIgnored private var receiptBytes = 0
    @ObservationIgnored private let approval: ((String, String) async -> Bool)?
    @ObservationIgnored private let credentials: (UUID, Data?, Bool) throws -> Data?
    var socketPath: String { root.appendingPathComponent("host.sock").path }
    var connectionCount: Int { connected.count }
    init(workspace: ProjectWorkspace, defaults: UserDefaults = .standard, root: URL? = nil,
         approval: ((String, String) async -> Bool)? = nil,
         credentials: @escaping (UUID, Data?, Bool) throws -> Data? = { try MCPBridgeAuth.keychain($0, save: $1, delete: $2) }) {
        self.workspace = workspace; self.defaults = defaults; self.approval = approval; self.credentials = credentials
        self.root = root ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".mcp-live", isDirectory: true)
        if let data = defaults.data(forKey: "mcp.clients"), let saved = try? JSONDecoder().decode([MCPClientGrant].self, from: data) { clients = saved }
        if let bookmark = defaults.data(forKey: "mcp.outputBookmark") {
            var stale = false
            folder = try? URL(resolvingBookmarkData: bookmark, options: [.withSecurityScope], bookmarkDataIsStale: &stale)
            if stale { folder = nil }
        }
    }
    func restore() { if defaults.bool(forKey: "mcp.enabled") { setEnabled(true) } }
    func setEnabled(_ value: Bool) {
        stop()
        defaults.set(value, forKey: "mcp.enabled")
        guard value else { return }
        instance = UUID().uuidString
        receipts.removeAll(); receiptOrder.removeAll(); seen.removeAll(); receiptBytes = 0
        do {
            server = try MCPUnixServer(path: socketPath, instance: instance,
                receive: { [weak self] connection, packet in
                    guard let value = try? JSONSerialization.jsonObject(with: packet) as? [String: Any] else {
                        connection.send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32700, "message": "Parse error"]]); return
                    }
                    self?.receive(connection, value)
                },
                disconnected: { [weak self] id in self?.disconnect(id) })
            enabled = true; error = nil
        } catch { self.error = error.localizedDescription }
    }
    func stop() {
        enabled = false; authorizationRevision = UUID()
        for group in tasks.values { for task in group.values { task.cancel() } }
        for watcher in watchers.values { watcher.cancel() }; watchers.removeAll(); legacySubscriptions.removeAll()
        server?.stop(); server = nil; peers.removeAll(); connected.removeAll(); legacyVersions.removeAll()
    }
    func setPaused(_ value: Bool) {
        paused = value; authorizationRevision = UUID()
        if value { for group in tasks.values { for task in group.values { task.cancel() } } }
    }
    func update(_ client: MCPClientGrant) {
        guard let index = clients.firstIndex(where: { $0.id == client.id }) else { return }
        clients[index] = client; authorizationRevision = UUID(); persist()
        for connection in connected.keys where connected[connection] == client.id { for task in tasks[connection]?.values ?? Dictionary<String, Task<Void, Never>>().values { task.cancel() } }
        if client.paused { for id in connected.keys where connected[id] == client.id { peers[id]?.close(); disconnect(id) } }
    }
    private func persist() { defaults.set(try? JSONEncoder().encode(clients), forKey: "mcp.clients") }
    @discardableResult func addClient(name: String) throws -> MCPClientGrant {
        guard clients.count < 16 else { throw MCPBridgeError.message("At most sixteen clients can be registered.") }
        let clean = String(String(name.unicodeScalars.filter { !CharacterSet.controlCharacters.contains($0) }).trimmingCharacters(in: .whitespacesAndNewlines).prefix(60))
        guard !clean.isEmpty else { throw ProjectError.invalid }
        let client = MCPClientGrant(id: UUID(), name: clean)
        let secret = try MCPBridgeAuth.secret()
        _ = try credentials(client.id, secret, false)
        do {
            try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            chmod(root.path, 0o700)
            let config: [String: Any] = ["clientID": client.id.uuidString, "secret": secret.base64EncodedString(), "socket": socketPath]
            let data = try JSONSerialization.data(withJSONObject: config)
            let url = credentialURL(client.id)
            let fd = Darwin.open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW, 0o600)
            guard fd >= 0 else { throw CocoaError(.fileWriteFileExists) }
            let file = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            try file.write(contentsOf: data); try file.close()
            clients.append(client); selectedClientID = client.id; persist(); return client
        } catch { _ = try? credentials(client.id, nil, true); throw error }
    }
    func revoke(_ id: UUID) {
        authorizationRevision = UUID()
        for connection in Array(connected.keys) where connected[connection] == id { peers[connection]?.close(); disconnect(connection) }
        _ = try? credentials(id, nil, true); try? FileManager.default.removeItem(at: credentialURL(id))
        authorized.removeValue(forKey: id); clients.removeAll { $0.id == id }; persist()
    }
    private func credentialURL(_ id: UUID) -> URL { root.appendingPathComponent(id.uuidString + ".json") }
    func configuration(for id: UUID) throws -> String {
        guard clients.contains(where: { $0.id == id }) else { throw ProjectError.invalid }
        let executable = Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/compositor-cli").path
        let value: [String: Any] = ["mcpServers": ["compositor-live": ["command": executable,
            "args": ["mcp", "--live", "--config", credentialURL(id).path]]]]
        return String(decoding: try JSONSerialization.data(withJSONObject: value, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]), as: UTF8.self)
    }
    func authorizeCurrentDocument(for id: UUID) { authorized[id] = [workspace.current.id]; authorizationRevision = UUID() }
    func authorizedDocumentNames(for client: UUID) -> String {
        let names = workspace.tabs.filter { isAuthorized(client, tab: $0) && $0.session.document != nil }.map(\.title)
        return names.isEmpty ? L10n.text("No document authorized") : names.joined(separator: ", ")
    }
    func isAuthorized(_ client: UUID, tab: ProjectTab) -> Bool { authorized[client]?.contains(tab.id) == true }
    func chooseFolder() async {
        let panel = NSOpenPanel(); panel.canChooseDirectories = true; panel.canChooseFiles = false
        panel.prompt = L10n.text("Choose"); panel.message = L10n.text("MCP can create new files only in this folder.")
        guard await panel.begin() == .OK, let url = panel.url else { return }
        do { try setFolder(url) } catch { self.error = error.localizedDescription }
    }
    func setFolder(_ url: URL) throws {
        let bookmark = try url.bookmarkData(options: [.withSecurityScope], includingResourceValuesForKeys: nil, relativeTo: nil)
        defaults.set(bookmark, forKey: "mcp.outputBookmark"); folder = url; authorizationRevision = UUID()
    }
    private func client(_ id: UUID) throws -> MCPClientGrant {
        guard enabled, !paused, let client = clients.first(where: { $0.id == id }), !client.paused else { throw MCPBridgeError.message("The connection is paused or revoked.") }
        return client
    }
    private func permission(_ id: UUID, scope: String, tab: ProjectTab? = nil) -> Bool {
        guard let grant = try? client(id) else { return false }
        guard grant.read else { return false }
        let allowed = scope == "read" ? grant.read : scope == "files" ? grant.files : scope == "destructive" ? grant.destructive : grant.edit
        return allowed && (tab == nil || (workspace.tabs.contains(where: { $0 === tab }) && isAuthorized(id, tab: tab!)))
    }
    private func ensureApproval(_ id: UUID) async throws {
        let grant = try client(id)
        guard authorized[id] == nil else { return }
        let tab = workspace.current
        let authorization = authorizationRevision
        let scopes = [grant.read ? L10n.text("Read documents and previews") : nil, grant.edit ? L10n.text("Edit layers") : nil,
            grant.files ? L10n.text("Open and save files") : nil, grant.destructive ? L10n.text("Delete and close") : nil].compactMap { $0 }.joined(separator: "\n")
        guard try await confirm(L10n.format("Allow %@ to connect?", grant.name),
            L10n.format("Only this document: %@", tab.title) + "\n\n" + scopes), (try? client(id)) != nil, authorizationRevision == authorization,
            workspace.tabs.contains(where: { $0 === tab }) else { throw MCPBridgeError.message("Connection not authorized.") }
        authorized[id] = [tab.id]; authorizationRevision = UUID()
    }
    private func confirm(_ title: String, _ message: String) async throws -> Bool {
        guard !pendingApproval, !Task.isCancelled else { throw MCPBridgeError.message("Another confirmation is open. Try again later.") }
        pendingApproval = true; defer { pendingApproval = false }
        if let approval { return await approval(title, message) }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert(); alert.messageText = title; alert.informativeText = message
        alert.addButton(withTitle: L10n.text("Allow")); alert.addButton(withTitle: L10n.text("Cancel"))
        if let window = workspace.window {
            guard window.attachedSheet == nil else { throw MCPBridgeError.message("Finish the open dialog first.") }
            return await alert.beginSheetModal(for: window) == .alertFirstButtonReturn
        }
        return alert.runModal() == .alertFirstButtonReturn
    }
    private func disconnect(_ id: UUID) {
        for task in tasks.removeValue(forKey: id)?.values ?? Dictionary<String, Task<Void, Never>>().values { task.cancel() }
        watchers.removeValue(forKey: id)?.cancel(); legacySubscriptions.removeValue(forKey: id)
        peers.removeValue(forKey: id); connected.removeValue(forKey: id); legacyVersions.removeValue(forKey: id)
    }
    private func receive(_ connection: MCPUnixConnection, _ request: [String: Any]) {
        if connected[connection.id] == nil {
            guard enabled, !paused, let id = (request["clientID"] as? String).flatMap(UUID.init(uuidString:)),
                  let _ = try? client(id), let secret = try? credentials(id, nil, false),
                  let clientNonce = request["clientNonce"] as? String, UUID(uuidString: clientNonce) != nil,
                  let proof = request["proof"] as? String,
                  MCPBridgeAuth.matches(proof, MCPBridgeAuth.proof(secret: secret, challenge: connection.challenge + "\n" + clientNonce, instance: instance, role: "client")) else { connection.close(); return }
            connection.markAuthenticated()
            connected[connection.id] = id; peers[connection.id] = connection
            connection.send(["authenticated": true, "proof": MCPBridgeAuth.proof(secret: secret, challenge: connection.challenge + "\n" + clientNonce, instance: instance, role: "server")]); return
        }
        let params = request["params"] as? [String: Any] ?? [:]
        if request["method"] as? String == "notifications/cancelled" {
            if let requestID = params["requestId"] { tasks[connection.id]?[Self.requestKey(requestID)]?.cancel() }; return
        }
        guard let id = request["id"] else { return }
        let key = Self.requestKey(id)
        guard (id as? String).map({ $0.count <= 1024 }) ?? ((id as? NSNumber).map({ CFGetTypeID($0) != CFBooleanGetTypeID() }) == true), request["jsonrpc"] as? String == "2.0" else {
            connection.send(["jsonrpc": "2.0", "id": NSNull(), "error": ["code": -32600, "message": "Invalid request"]]); return
        }
        guard tasks[connection.id]?[key] == nil, (tasks[connection.id]?.count ?? 0) < 8 else {
            connection.send(["jsonrpc": "2.0", "id": id, "error": ["code": -32600, "message": "Duplicate request ID or too many pending requests"]]); return
        }
        tasks[connection.id, default: [:]][key] = Task { [weak self] in
            guard let self else { return }
            defer { self.tasks[connection.id]?.removeValue(forKey: key) }
            connection.send(await self.respond(request, connection: connection.id))
        }
    }
    private static func requestKey(_ id: Any) -> String { (id is String ? "s:" : "n:") + String(describing: id) }
    private func respond(_ request: [String: Any], connection: UUID) async -> [String: Any] {
        let id = request["id"] ?? NSNull()
        func failure(_ code: Int, _ message: String, data: [String: Any]? = nil) -> [String: Any] {
            var error: [String: Any] = ["code": code, "message": message]; error["data"] = data
            return ["jsonrpc": "2.0", "id": id, "error": error]
        }
        guard let clientID = connected[connection], let _ = try? client(clientID), !Task.isCancelled else { return failure(-32000, "Connection unavailable") }
        let method = request["method"] as? String ?? ""
        let params = request["params"] as? [String: Any] ?? [:]
        let meta = params["_meta"] as? [String: Any] ?? [:]
        let modernVersion = meta["io.modelcontextprotocol/protocolVersion"] as? String
        let modern = modernVersion != nil || method == "server/discover"
        if let version = modernVersion, version != "2026-07-28" {
            return failure(-32022, "Unsupported protocol version", data: ["supported": ["2026-07-28", "2025-11-25"], "requested": version])
        }
        if modern, method != "server/discover", meta["io.modelcontextprotocol/clientCapabilities"] as? [String: Any] == nil {
            return failure(-32602, "Modern requests require clientCapabilities metadata")
        }
        if !modern, method != "initialize", legacyVersions[connection] == nil { return failure(-32000, "Initialize the legacy connection first") }
        var result: [String: Any]
        switch method {
        case "initialize":
            guard !modern, legacyVersions[connection] == nil else { return failure(-32600, "Invalid initialization") }
            let wanted = params["protocolVersion"] as? String ?? ""
            let version = MCPProtocol.legacyVersions.contains(wanted) ? wanted : "2025-11-25"
            legacyVersions[connection] = version
            result = ["protocolVersion": version, "capabilities": ["tools": ["listChanged": false], "resources": ["subscribe": true, "listChanged": true], "prompts": ["listChanged": false]], "serverInfo": ["name": "Compositor Live", "version": "1.4.8"]]
        case "server/discover":
            result = ["supportedVersions": ["2026-07-28"] + MCPProtocol.legacyVersions, "capabilities": ["tools": [:], "resources": ["subscribe": true, "listChanged": true], "prompts": [:]],
                "ttlMs": 0, "cacheScope": "private", "instructions": "Explicit live-document server. Authorize documents in the app. Fetch fresh tokens before writing. Reuse operationID for retries; never replace an unknown receipt with a new ID."]
        case "ping": result = [:]
        case "resources/list", "resources/read", "resources/subscribe", "resources/unsubscribe":
            do {
                try await ensureApproval(clientID)
                guard permission(clientID, scope: "read") else { throw MCPBridgeError.message("Read permission required.") }
                if method == "resources/list" {
                    guard params["cursor"] == nil else { throw ProjectError.invalid }
                    result = ["resources": workspace.tabs.filter { isAuthorized(clientID, tab: $0) && $0.session.document != nil }.map {
                        ["uri": resourceURI($0), "name": $0.title, "mimeType": "application/json", "description": "Live document state and revision tokens"] }]
                    if modern { result["ttlMs"] = 0; result["cacheScope"] = "private" }
                } else {
                    guard let uri = params["uri"] as? String else { throw ProjectError.invalid }
                    let target = try resourceTab(uri, clientID: clientID)
                    if method == "resources/read" {
                        result = ["contents": [["uri": uri, "mimeType": "application/json", "text": String(decoding: try JSONSerialization.data(withJSONObject: state(target), options: [.sortedKeys]), as: UTF8.self)]]]
                        if modern { result["ttlMs"] = 0; result["cacheScope"] = "private" }
                    } else {
                        guard !modern else { return failure(-32601, "Use subscriptions/listen for modern subscriptions") }
                        if method == "resources/subscribe" {
                            guard (legacySubscriptions[connection]?.count ?? 0) < 32 else { throw ProjectError.tooLarge }
                            legacySubscriptions[connection, default: []].insert(uri); startLegacyWatcher(connection, clientID: clientID)
                        } else { legacySubscriptions[connection]?.remove(uri) }
                        result = [:]
                    }
                }
                recordRead(clientID, tool: method, status: "complete")
            } catch { return failure(-32000, "Resource is unavailable or unauthorized") }
        case "subscriptions/listen":
            guard modern, let filter = params["notifications"] as? [String: Any] else { return failure(-32602, "Invalid subscription filter") }
            do {
                try await ensureApproval(clientID)
                result = try await listen(connection, clientID: clientID, id: id, filter: filter)
            } catch { return failure(-32000, "Subscription is unavailable or unauthorized") }
        case "prompts/list":
            guard params["cursor"] == nil else { return failure(-32602, "Unknown cursor") }
            result = ["prompts": [["name": "poster_brief", "description": "Plan a poster edit and verify a preview before exporting.", "arguments": [["name": "brief", "description": "Desired poster changes", "required": true]]],
                ["name": "document_review", "description": "Review an authorized document without changing it."]]]
            if modern { result["ttlMs"] = 0; result["cacheScope"] = "private" }
        case "prompts/get":
            guard let name = params["name"] as? String, ["poster_brief", "document_review"].contains(name) else { return failure(-32602, "Unknown prompt") }
            let args = params["arguments"] as? [String: String] ?? [:]
            guard args.keys.allSatisfy({ $0 == "brief" }), (args["brief"]?.count ?? 0) <= 4000,
                  name != "poster_brief" || args["brief"]?.isEmpty == false else { return failure(-32602, "Invalid prompt arguments") }
            let text = name == "document_review" ? "Use list_documents, get_document and render_preview to review an authorized live document. Explain concrete improvements. Do not edit or write files." :
                "Read the authorized document and render a preview. Propose changes for this brief: " + (args["brief"] ?? "") + "\nUse execute_commands with fresh tokens and one operationID per batch. Inspect the resulting preview. Obtain the user's approval before exporting a new copy. Never overwrite existing files."
            result = ["description": name, "messages": [["role": "user", "content": ["type": "text", "text": text]]]]
        case "tools/list":
            if params["cursor"] != nil { return failure(-32602, "Unknown cursor") }
            result = ["tools": MCPLiveCatalog.tools]
            if modern { result["ttlMs"] = 0; result["cacheScope"] = "private" }
        case "tools/call":
            guard let name = params["name"] as? String, let arguments = params["arguments"] as? [String: Any] else { return failure(-32602, "Invalid tool call") }
            do { try MCPLiveCatalog.validate(name, arguments: arguments) }
            catch { return failure(-32602, "Invalid tool arguments") }
            do {
                let value = try await MCPToolRouter.callLive(name, arguments: arguments, host: MCPAuthorizedLiveHost(service: self, clientID: clientID))
                if MCPLiveCatalog.reads.contains(MCPLiveCatalog.aliases[name] ?? name) { recordRead(clientID, tool: name, status: "complete") }
                var structured = value; let image = structured.removeValue(forKey: "_image") as? String
                result = try MCPProtocol.legacyToolResult(structured)
                result["structuredContent"] = structured
                if let image { result["content"] = [["type": "image", "mimeType": "image/png", "data": image], ["type": "text", "text": String(decoding: try JSONSerialization.data(withJSONObject: structured), as: UTF8.self)]] }
            } catch { recordRead(clientID, tool: name, status: "failed"); result = MCPProtocol.legacyToolError(error) }
        default: return failure(-32601, "Method not found")
        }
        if modern {
            result["resultType"] = "complete"
            var resultMeta = result["_meta"] as? [String: Any] ?? [:]
            resultMeta["io.modelcontextprotocol/serverInfo"] = ["name": "Compositor Live", "version": "1.4.8"]
            result["_meta"] = resultMeta
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }
    private func recordRead(_ clientID: UUID, tool: String, status: String) {
        activities.insert(MCPActivity(id: UUID(), date: Date(), client: clients.first { $0.id == clientID }?.name ?? "Client", tool: tool, status: status, tabID: nil, undoRevision: nil, changeToken: nil), at: 0)
        if activities.count > 2000 { activities.removeLast(activities.count - 2000) }
    }
    private func resourceURI(_ tab: ProjectTab) -> String { "compositor://document/" + handle(tab) }
    private func resourceTab(_ uri: String, clientID: UUID) throws -> ProjectTab {
        let prefix = "compositor://document/"
        guard uri.hasPrefix(prefix) else { throw ProjectError.invalid }
        let tab = try tab(String(uri.dropFirst(prefix.count)))
        guard permission(clientID, scope: "read", tab: tab) else { throw ProjectError.invalid }
        return tab
    }
    private func resourceStamps(_ clientID: UUID) -> [String: String] {
        guard permission(clientID, scope: "read") else { return [:] }
        return Dictionary(uniqueKeysWithValues: workspace.tabs.filter { isAuthorized(clientID, tab: $0) && $0.session.document != nil }.map {
            (resourceURI($0), $0.session.automationChangeToken.uuidString + $0.session.lockRevision.uuidString)
        })
    }
    private func startLegacyWatcher(_ connection: UUID, clientID: UUID) {
        guard watchers[connection] == nil else { return }
        watchers[connection] = Task { [weak self] in
            guard let self else { return }
            var stamps = resourceStamps(clientID)
            while !Task.isCancelled, connected[connection] == clientID {
                do { try await Task.sleep(nanoseconds: 500_000_000) } catch { break }
                guard permission(clientID, scope: "read") else { break }
                let latest = resourceStamps(clientID)
                if Set(stamps.keys) != Set(latest.keys) { peers[connection]?.send(["jsonrpc": "2.0", "method": "notifications/resources/list_changed"]) }
                for uri in legacySubscriptions[connection] ?? [] where latest[uri] != nil && latest[uri] != stamps[uri] {
                    peers[connection]?.send(["jsonrpc": "2.0", "method": "notifications/resources/updated", "params": ["uri": uri]])
                }
                stamps = latest
            }
            watchers.removeValue(forKey: connection)
        }
    }
    private func listen(_ connection: UUID, clientID: UUID, id: Any, filter: [String: Any]) async throws -> [String: Any] {
        guard filter.keys.allSatisfy({ ["toolsListChanged", "promptsListChanged", "resourcesListChanged", "resourceSubscriptions"].contains($0) }),
              permission(clientID, scope: "read"), let peer = peers[connection] else { throw ProjectError.invalid }
        let uris = filter["resourceSubscriptions"] as? [String] ?? []
        guard uris.count <= 32 else { throw ProjectError.tooLarge }
        for uri in uris { _ = try resourceTab(uri, clientID: clientID) }
        let listChanges = filter["resourcesListChanged"] as? Bool == true
        let meta: [String: Any] = ["io.modelcontextprotocol/subscriptionId": id]
        var honored: [String: Any] = ["resourceSubscriptions": uris]
        if listChanges { honored["resourcesListChanged"] = true }
        peer.send(["jsonrpc": "2.0", "method": "notifications/subscriptions/acknowledged", "params": ["notifications": honored, "_meta": meta]])
        var stamps = resourceStamps(clientID)
        let authorization = authorizationRevision
        while !Task.isCancelled, connected[connection] == clientID, authorizationRevision == authorization {
            do { try await Task.sleep(nanoseconds: 500_000_000) } catch { break }
            guard !Task.isCancelled, authorizationRevision == authorization, permission(clientID, scope: "read") else { break }
            let latest = resourceStamps(clientID)
            if listChanges, Set(latest.keys) != Set(stamps.keys) { peer.send(["jsonrpc": "2.0", "method": "notifications/resources/list_changed", "params": ["_meta": meta]]) }
            for uri in uris where latest[uri] != nil && latest[uri] != stamps[uri] {
                peer.send(["jsonrpc": "2.0", "method": "notifications/resources/updated", "params": ["uri": uri, "_meta": meta]])
            }
            stamps = latest
        }
        return ["_meta": meta]
    }
    private func handle(_ tab: ProjectTab) -> String { instance + ":" + tab.id.uuidString + ":" + (tab.session.document?.id.uuidString ?? "empty") }
    private func tab(_ handle: String) throws -> ProjectTab {
        guard let tab = workspace.tabs.first(where: { self.handle($0) == handle }), tab.session.document != nil else { throw MCPBridgeError.message("Unknown or expired document handle.") }
        return tab
    }
    private func state(_ tab: ProjectTab) -> [String: Any] {
        var result = tab.session.automationState()
        result["handle"] = handle(tab); result["changeToken"] = tab.session.automationChangeToken.uuidString
        result["selectedLayerIDs"] = tab.session.selectedLayerIDs.map(\.uuidString)
        result["modified"] = tab.session.isModified; result["zoom"] = tab.session.viewport.zoom
        return result
    }
    private func checkTokens(_ arguments: [String: Any], tab: ProjectTab) throws {
        guard arguments["expectedRevision"] as? String == tab.session.history.currentRevision.uuidString,
              arguments["expectedChangeToken"] as? String == tab.session.automationChangeToken.uuidString,
              arguments["expectedLockRevision"] as? String == tab.session.lockRevision.uuidString,
              tab.session.canEditLayers, !tab.session.history.hasPendingEdit, tab.session.effectsEditing == nil else {
            throw MCPBridgeError.message("Stale document tokens or an edit is in progress. Read the document again.")
        }
    }
    func callTool(_ supplied: String, arguments a: [String: Any], clientID: UUID) async throws -> [String: Any] {
        try MCPLiveCatalog.validate(supplied, arguments: a)
        let name = MCPLiveCatalog.aliases[supplied] ?? supplied
        _ = try client(clientID)
        if name == "get_capabilities" { return ["mode": "live", "operationPrefix": instance + ":", "maximumMessageBytes": MCPProtocol.maximumMessageBytes,
            "maximumBatchCommands": 500, "maximumOperationIDs": 2048, "maximumRetainedReceipts": 128, "commands": MCPToolCatalog.commandSchema, "previewLongSide": [256, 2048], "filePolicy": "approved-folder, new-copy-only", "resources": true, "subscriptions": true] }
        if name == "get_operation_result" {
            guard permission(clientID, scope: "read") else { throw MCPBridgeError.message("Read permission required.") }
            let key = clientID.uuidString + ":" + (a["operationID"] as? String ?? "")
            return try authorizedReceipt(key, clientID: clientID) ?? ["status": seen[key] == nil ? "unknown" : "receipt_expired", "mayHaveCommitted": true]
        }
        try await ensureApproval(clientID)
        if name == "list_documents" {
            guard permission(clientID, scope: "read") else { throw MCPBridgeError.message("Read permission required.") }
            return ["documents": workspace.tabs.filter { isAuthorized(clientID, tab: $0) && $0.session.document != nil }.map {
                ["handle": handle($0), "name": $0.title, "revision": $0.session.history.currentRevision.uuidString, "changeToken": $0.session.automationChangeToken.uuidString] }]
        }
        let target = try (a["handle"] as? String).map { try tab($0) }
        let scope = MCPLiveCatalog.reads.contains(name) ? "read" : MCPLiveCatalog.files.contains(name) ? "files" : name == "close_document" ? "destructive" : "edit"
        guard permission(clientID, scope: scope, tab: target) else { throw MCPBridgeError.message("This client is not authorized for the operation or document.") }
        if name == "get_document", let target { return state(target) }
        if name == "render_preview", let target {
            guard let snapshot = target.session.projectSnapshot(), target.session.canEditLayers, !target.session.history.hasPendingEdit, !target.session.animationPlaying else { throw MCPBridgeError.message("Finish the current edit or playback first.") }
            let captured = state(target)
            let raster = try await ImageExporter.shared.render(snapshot, longSide: (a["longSide"] as? NSNumber)?.intValue ?? 1024)
            let data = try await ImageExporter.shared.pngData(raster)
            guard permission(clientID, scope: "read", tab: target), !Task.isCancelled else { throw CancellationError() }
            return ["state": captured, "width": raster.image.width, "height": raster.image.height, "originalWidth": snapshot.manifest.width,
                "originalHeight": snapshot.manifest.height, "_image": data.base64EncodedString()]
        }
        guard !MCPLiveCatalog.reads.contains(name), let operation = a["operationID"] as? String,
              operation.hasPrefix(instance + ":"), UUID(uuidString: String(operation.dropFirst(instance.count + 1))) != nil else { throw MCPBridgeError.message("A current-server operationID is required.") }
        let key = clientID.uuidString + ":" + operation
        let digest = Data(SHA256.hash(data: try JSONSerialization.data(withJSONObject: ["name": name, "arguments": a], options: [.sortedKeys])))
        if let previous = seen[key] {
            guard previous == digest else { throw MCPBridgeError.message("operationID was reused with different arguments.") }
            return try authorizedReceipt(key, clientID: clientID) ?? ["status": "pending_or_expired", "mayHaveCommitted": true]
        }
        guard seen.count < 2048 else { throw MCPBridgeError.message("The operation receipt limit was reached. Restart the bridge before creating more operations.") }
        seen[key] = digest
        do {
            if let target { try checkTokens(a, tab: target) }
            let before = target?.session.history.currentRevision
            let value = try await mutate(name, a: a, clientID: clientID, target: target, authorization: authorizationRevision)
            storeReceipt(value, key: key)
            let after = target?.session.history.currentRevision
            activities.insert(MCPActivity(id: UUID(), date: Date(), client: clients.first { $0.id == clientID }?.name ?? "Client", tool: name,
                status: value["status"] as? String ?? "complete", tabID: target?.id, undoRevision: before != after ? after : nil,
                changeToken: target?.session.automationChangeToken), at: 0)
            if activities.count > 2000 { activities.removeLast(activities.count - 2000) }
            return value
        } catch {
            let value: [String: Any] = ["status": "failed", "message": error.localizedDescription, "operationID": operation]
            storeReceipt(value, key: key)
            activities.insert(MCPActivity(id: UUID(), date: Date(), client: clients.first { $0.id == clientID }?.name ?? "Client", tool: name, status: "failed", tabID: target?.id, undoRevision: nil, changeToken: nil), at: 0)
            if activities.count > 2000 { activities.removeLast() }
            return value
        }
    }
    private func authorizedReceipt(_ key: String, clientID: UUID) throws -> [String: Any]? {
        guard let value = receipts[key] else { return nil }
        if let source = (value["state"] as? [String: Any]) ?? (value["handle"] != nil ? value : nil), let handle = source["handle"] as? String {
            guard let target = try? tab(handle), permission(clientID, scope: "read", tab: target) else { throw MCPBridgeError.message("Read permission required.") }
        }
        return value
    }
    private func storeReceipt(_ value: [String: Any], key: String) {
        let size = (try? JSONSerialization.data(withJSONObject: value).count) ?? 0
        guard size <= 1024 * 1024 else { return }
        receipts[key] = value; receiptOrder.append(key); receiptBytes += size
        while receiptOrder.count > 128 || receiptBytes > 16 * 1024 * 1024 {
            let old = receiptOrder.removeFirst()
            if let removed = receipts.removeValue(forKey: old) { receiptBytes -= (try? JSONSerialization.data(withJSONObject: removed).count) ?? 0 }
        }
    }
    private func destructive(_ name: String, _ a: [String: Any]) -> Bool {
        if ["close_document", "undo", "redo"].contains(name) { return true }
        let commands = a["commands"] as? [[String: Any]] ?? []
        return commands.contains { ["remove", "setMask", "vectorMask", "textOutlines", "invert", "fillPixels", "filter", "refineEdges"].contains($0["kind"] as? String ?? "") }
    }
    private func mutate(_ name: String, a: [String: Any], clientID: UUID, target: ProjectTab?, authorization: UUID) async throws -> [String: Any] {
        let scope = MCPLiveCatalog.files.contains(name) ? "files" : name == "close_document" ? "destructive" : "edit"
        if destructive(name, a) {
            let action: String
            switch name {
            case "close_document": action = L10n.text("Close Document")
            case "undo": action = L10n.text("Undo")
            case "redo": action = L10n.text("Redo")
            default: action = L10n.text("Edit Command Batch")
            }
            guard permission(clientID, scope: "destructive", tab: target), try await confirm(L10n.text("Confirm AI change"),
                L10n.format("%@ requests %@. Check the current document before allowing this change.", clients.first { $0.id == clientID }!.name, action)) else { throw MCPBridgeError.message("Destructive change not authorized.") }
        }
        guard authorizationRevision == authorization, permission(clientID, scope: scope, tab: target), !Task.isCancelled else { throw CancellationError() }
        if let target { try checkTokens(a, tab: target) }
        if name == "new_document" {
            guard workspace.canSwitch, let w = a["width"] as? Int, let h = a["height"] as? Int, w * h <= DocumentLimits.maxSurfacePixels else { throw ProjectError.invalid }
            let tab = workspace.addTab(reuseEmpty: true); tab.session.createNewProject(width: w, height: h)
            authorized[clientID, default: []].insert(tab.id); return state(tab)
        }
        if name == "open_document" {
            guard workspace.canSwitch else { throw MCPBridgeError.message("Finish the current edit first.") }
            let panel = NSOpenPanel(); panel.allowedContentTypes = [.compositorProject]
            if let path = a["path"] as? String { panel.directoryURL = URL(fileURLWithPath: path).deletingLastPathComponent() }
            guard await panel.begin() == .OK, let url = panel.url, authorizationRevision == authorization, permission(clientID, scope: "files"), !Task.isCancelled else { throw CancellationError() }
            let accessing = url.startAccessingSecurityScopedResource(); defer { if accessing { url.stopAccessingSecurityScopedResource() } }
            let staged = ProjectTab(name: url.deletingPathExtension().lastPathComponent)
            guard await staged.controller.open(url), authorizationRevision == authorization, permission(clientID, scope: "files"),
                  !Task.isCancelled, workspace.adoptOpenedTab(staged) else { throw CancellationError() }
            authorized[clientID, default: []].insert(staged.id); return state(staged)
        }
        guard let target else { throw ProjectError.invalid }
        let session = target.session
        if name == "execute_commands" {
            var fields = a; for key in ["handle", "operationID"] { fields.removeValue(forKey: key) }
            let request = try JSONDecoder().decode(PosterBatchRequest.self, from: JSONSerialization.data(withJSONObject: fields))
            let outcome = await session.executePosterBatch(request, canCommit: { [weak self, weak target] in
                guard let self, let target else { return false }
                return self.authorizationRevision == authorization && self.permission(clientID, scope: "edit", tab: target) && (!self.destructive(name, a) || self.permission(clientID, scope: "destructive", tab: target))
            })
            return ["status": outcome.status, "errorCode": outcome.errorCode ?? "", "message": outcome.message ?? "", "state": state(target)]
        }
        if name == "undo" || name == "redo" {
            guard name == "undo" ? session.canUndo : session.canRedo else { throw MCPBridgeError.message("No history step is available.") }
            if name == "undo" { session.undo() } else { session.redo() }; return state(target)
        }
        if name == "set_layer_locks" {
            guard let id = (a["layerID"] as? String).flatMap(UUID.init(uuidString:)), session.document?.layers.contains(where: { $0.id == id }) == true,
                  let bits = a["locks"] as? Int, (0...31).contains(bits) else { throw ProjectError.invalid }
            session.lockDocumentID = session.document?.id; session.layerLocks[id] = bits == 0 ? nil : LayerLocks(rawValue: bits)
            return state(target)
        }
        if name == "select_layers" {
            guard let raw = a["layerIDs"] as? [String] else { throw ProjectError.invalid }
            let ids = Set(raw.compactMap(UUID.init(uuidString:)))
            guard ids.count == raw.count, ids.allSatisfy({ id in session.document?.layers.contains(where: { $0.id == id }) == true }) else { throw ProjectError.invalid }
            session.selectedLayerIDs = ids; session.activeLayerID = raw.first.flatMap(UUID.init(uuidString:)); return state(target)
        }
        if name == "set_view" {
            if a["fit"] as? Bool == true { session.fit() }
            else if let zoom = a["zoom"] as? Double, zoom.isFinite, (0.01...64).contains(zoom) { session.zoom(to: zoom) }
            else { throw ProjectError.invalid }; return state(target)
        }
        if name == "close_document" {
            if session.isModified {
                guard try await confirm(L10n.text("Discard Unsaved Changes?"), L10n.text("Closing this document will discard unsaved changes.")),
                      permission(clientID, scope: "destructive", tab: target), !Task.isCancelled else { throw CancellationError() }
                try checkTokens(a, tab: target)
            }
            guard workspace.canSwitch else { throw MCPBridgeError.message("Finish the current edit first.") }
            guard authorizationRevision == authorization, permission(clientID, scope: "destructive", tab: target), !Task.isCancelled else { throw CancellationError() }
            try checkTokens(a, tab: target); workspace.removeTab(target.id)
            await session.recovery?.finishNormally()
            return ["closed": a["handle"]!]
        }
        guard let folder, let snapshot = session.projectSnapshot() else { throw MCPBridgeError.message("Choose an MCP output folder in Settings first.") }
        let accessing = folder.startAccessingSecurityScopedResource(); defer { if accessing { folder.stopAccessingSecurityScopedResource() } }
        let root = folder.resolvingSymlinksInPath()
        let values = try folder.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        guard values.isDirectory == true, values.isSymbolicLink != true else { throw ProjectError.invalid }
        let directoryFD = Darwin.open(root.path, O_RDONLY | O_DIRECTORY | O_NOFOLLOW)
        guard directoryFD >= 0 else { throw ProjectError.invalid }
        defer { Darwin.close(directoryFD) }
        var originalDirectory = stat()
        guard fstat(directoryFD, &originalDirectory) == 0 else { throw ProjectError.invalid }
        let stageFolder = root.appendingPathComponent(".mcp-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: stageFolder, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { try? FileManager.default.removeItem(at: stageFolder) }
        let generated: URL, output: URL
        if name == "batch_export_document" {
            let fields = a["options"] as! [String: Any]
            let options = try JSONDecoder().decode(BatchExportOptions.self, from: JSONSerialization.data(withJSONObject: fields))
            let raw = a["layerIDs"] as? [String] ?? []
            let ids = Set(raw.compactMap(UUID.init(uuidString:)))
            guard ids.count == raw.count, ids.allSatisfy({ id in snapshot.manifest.layers.contains { $0.id == id } }) else { throw ProjectError.invalid }
            generated = try await BatchImageExporter.shared.export(snapshot, selected: ids, name: "Project", options: options, folder: stageFolder)
            output = root.appendingPathComponent(generated.lastPathComponent)
        } else {
            guard let filename = a["name"] as? String, !filename.isEmpty, filename.count <= 160,
                  !filename.hasPrefix("."), !filename.contains("/"), !filename.contains("\\"), !filename.contains(":"),
                  filename.rangeOfCharacter(from: .controlCharacters) == nil else { throw ProjectError.invalid }
            output = root.appendingPathComponent(filename); generated = stageFolder.appendingPathComponent(filename)
            if name == "save_document" {
                guard output.pathExtension.lowercased() == "comp" else { throw ProjectError.invalid }
                try await ProjectStore.shared.save(snapshot, to: generated, mustNotExist: true)
            } else if name == "export_document" {
                guard output.pathExtension.lowercased() == "png" else { throw ProjectError.invalid }
                try await ImageExporter.shared.write(ImageExporter.shared.pngData(snapshot), to: generated, mustNotExist: true)
            } else { throw ProjectError.invalid }
        }
        guard authorizationRevision == authorization, permission(clientID, scope: "files", tab: target), !Task.isCancelled,
              folder.resolvingSymlinksInPath() == root else { throw CancellationError() }
        try checkTokens(a, tab: target)
        // The kernel performs the final no-overwrite check, including files created while encoding.
        var currentDirectory = stat()
        guard lstat(root.path, &currentDirectory) == 0, currentDirectory.st_ino == originalDirectory.st_ino,
              currentDirectory.st_dev == originalDirectory.st_dev else { throw ProjectError.invalid }
        let relativeSource = stageFolder.lastPathComponent + "/" + generated.lastPathComponent
        guard renameatx_np(directoryFD, relativeSource, directoryFD, output.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        return ["outputName": output.lastPathComponent, "state": state(target)]
    }
    func canUndo(_ activity: MCPActivity) -> Bool {
        guard let id = activity.tabID, let revision = activity.undoRevision, let token = activity.changeToken,
              let tab = workspace.tabs.first(where: { $0.id == id }) else { return false }
        return tab.session.canUndo && tab.session.history.currentRevision == revision && tab.session.automationChangeToken == token
    }
    func undoActivity(_ activity: MCPActivity) { guard canUndo(activity), let tab = workspace.tabs.first(where: { $0.id == activity.tabID }) else { return }; tab.session.undo() }
}

@MainActor private struct MCPAuthorizedLiveHost: MCPDocumentHost {
    let service: MCPLiveService
    let clientID: UUID
    func executeMCPTool(_ name: String, arguments: [String: Any]) async throws -> [String: Any] {
        try await service.callTool(name, arguments: arguments, clientID: clientID)
    }
}
