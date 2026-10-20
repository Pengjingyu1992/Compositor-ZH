import Foundation
import CryptoKit
import Security
import Darwin

nonisolated enum MCPBridgeError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case let .message(text) = self { return L10n.text(text) }; return nil }
}

/// Both ends authenticate possession of a per-client secret. Client display names are never credentials.
nonisolated enum MCPBridgeAuth {
    static func secret() throws -> Data {
        var bytes = Data(count: 32)
        let status = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, 32, $0.baseAddress!) }
        guard status == errSecSuccess else { throw MCPBridgeError.message("Unable to create a client credential.") }
        return bytes
    }
    static func proof(secret: Data, challenge: String, instance: String, role: String) -> String {
        let data = Data("Compositor-live-v1\n\(role)\n\(instance)\n\(challenge)".utf8)
        return Data(HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: secret))).base64EncodedString()
    }
    static func matches(_ a: String, _ b: String) -> Bool {
        let lhs = Array(a.utf8), rhs = Array(b.utf8)
        guard lhs.count == rhs.count else { return false }
        return zip(lhs, rhs).reduce(UInt8(0)) { $0 | ($1.0 ^ $1.1) } == 0
    }
    static func keychain(_ id: UUID, save: Data? = nil, delete: Bool = false) throws -> Data? {
        let query: [String: Any] = [kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: "Compositor.LiveMCP", kSecAttrAccount as String: id.uuidString]
        if delete { SecItemDelete(query as CFDictionary); return nil }
        if let save {
            var item = query; item[kSecValueData as String] = save
            item[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
            let status = SecItemAdd(item as CFDictionary, nil)
            guard status == errSecSuccess else { throw MCPBridgeError.message("Unable to store the client credential in Keychain.") }
            return save
        }
        var item = query; item[kSecReturnData as String] = true; item[kSecMatchLimit as String] = kSecMatchLimitOne
        var value: CFTypeRef?
        let status = SecItemCopyMatching(item as CFDictionary, &value)
        guard status == errSecSuccess else { return nil }
        return value as? Data
    }
}

/// A newline-framed local channel with bounded messages, serialized writes and no main-thread socket I/O.
nonisolated final class MCPUnixConnection: @unchecked Sendable {
    let id = UUID()
    let challenge = UUID().uuidString + UUID().uuidString
    let fd: Int32
    private let writeQueue = DispatchQueue(label: "Compositor.MCP.write")
    private let lock = NSLock()
    private var closed = false
    init(fd: Int32) { self.fd = fd }
    private var queuedBytes = 0
    private var authenticated = false
    var messageLimit: Int { lock.lock(); defer { lock.unlock() }; return authenticated ? 32 * 1024 * 1024 : 8192 }
    func markAuthenticated() {
        lock.lock(); authenticated = true; lock.unlock()
        var timeout = timeval(tv_sec: 0, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
    }
    func send(_ object: [String: Any]) {
        guard var data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
        if data.count > 32 * 1024 * 1024 {
            guard let requestID = object["id"] else { close(); return }
            data = (try? JSONSerialization.data(withJSONObject: ["jsonrpc": "2.0", "id": requestID,
                "error": ["code": -32000, "message": "The result exceeds the message limit. Request a smaller preview or document scope."]])) ?? Data()
        }
        let packet = data + Data([10])
        lock.lock()
        guard !closed, queuedBytes + packet.count <= 64 * 1024 * 1024 else { lock.unlock(); close(); return }
        queuedBytes += packet.count; lock.unlock()
        writeQueue.async { [self] in
            defer { lock.lock(); queuedBytes -= packet.count; lock.unlock() }
            lock.lock(); let live = !closed; lock.unlock()
            guard live else { return }
            var offset = 0
            packet.withUnsafeBytes { bytes in
                while offset < packet.count {
                    let count = Darwin.write(fd, bytes.baseAddress! + offset, packet.count - offset)
                    if count < 0 && errno == EINTR { continue }
                    if count <= 0 { shutdown(fd, SHUT_RDWR); return }
                    offset += count
                }
            }
        }
    }
    func close() {
        lock.lock()
        guard !closed else { lock.unlock(); return }
        closed = true; shutdown(fd, SHUT_RDWR); lock.unlock()
        // Finish already queued writes before releasing the descriptor; repeated close never touches a recycled fd.
        _ = writeQueue.sync { Darwin.close(fd) }
    }

    deinit { close() }
}

nonisolated final class MCPUnixServer: @unchecked Sendable {
    let path: String
    private var listener: Int32 = -1
    private var fileLock: Int32 = -1
    private var ownsSocket = false
    private let lock = NSLock()
    private var connections: [UUID: MCPUnixConnection] = [:]
    private var stopped = false
    init(path: String, instance: String,
         receive: @escaping @MainActor @Sendable (MCPUnixConnection, Data) async -> Void,
         disconnected: @escaping @MainActor @Sendable (UUID) async -> Void) throws {
        self.path = path
        guard path.utf8.count < 104 else { throw MCPBridgeError.message("The local bridge path is too long.") }
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var parentStatus = stat()
        guard lstat(parent.path, &parentStatus) == 0, parentStatus.st_uid == getuid(), parentStatus.st_mode & S_IFMT == S_IFDIR,
              chmod(parent.path, 0o700) == 0 else { throw MCPBridgeError.message("Unable to protect the bridge directory.") }
        fileLock = Darwin.open(parent.appendingPathComponent("host.lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fileLock >= 0, flock(fileLock, LOCK_EX | LOCK_NB) == 0 else {
            if fileLock >= 0 { Darwin.close(fileLock); fileLock = -1 }
            throw MCPBridgeError.message("Another application instance owns the local bridge.")
        }
        var status = stat()
        if lstat(path, &status) == 0 {
            guard status.st_uid == getuid(), status.st_mode & S_IFMT == S_IFSOCK else { stop(); throw MCPBridgeError.message("Unsafe bridge endpoint.") }
            unlink(path)
        }
        listener = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let length = socklen_t(MemoryLayout<sockaddr_un>.size)
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.bind(listener, $0, length) } }
        ownsSocket = bound == 0
        guard listener >= 0, bound == 0, chmod(path, 0o600) == 0, listen(listener, 8) == 0 else {
            stop(); throw MCPBridgeError.message("Unable to start the local bridge.")
        }
        let serverFD = listener
        DispatchQueue.global(qos: .utility).async { [weak self] in
            while let self {
                self.lock.lock(); let stopped = self.stopped; self.lock.unlock()
                if stopped { break }
                let fd = accept(serverFD, nil, nil)
                if fd < 0 { if errno == EINTR { continue }; break }
                var uid: uid_t = 0, gid: gid_t = 0
                self.lock.lock()
                let allowed = !self.stopped && self.connections.count < 8 && getpeereid(fd, &uid, &gid) == 0 && uid == getuid()
                if !allowed { self.lock.unlock(); Darwin.close(fd); continue }
                let connection = MCPUnixConnection(fd: fd); self.connections[connection.id] = connection
                self.lock.unlock()
                var yes: Int32 = 1
                setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
                var timeout = timeval(tv_sec: 30, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
                var readTimeout = timeval(tv_sec: 10, tv_usec: 0)
                setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &readTimeout, socklen_t(MemoryLayout<timeval>.size))
                connection.send(["challenge": connection.challenge, "instance": instance])
                DispatchQueue.global(qos: .utility).async { [weak self] in
                    defer {
                        connection.close()
                        self?.lock.lock(); self?.connections.removeValue(forKey: connection.id); self?.lock.unlock()
                        Task { await disconnected(connection.id) }
                    }
                    let delivery = DispatchSemaphore(value: 1)
                    var pending = Data(), buffer = [UInt8](repeating: 0, count: 65536)
                    while true {
                        let count = Darwin.read(fd, &buffer, buffer.count)
                        if count < 0 && errno == EINTR { continue }
                        guard count > 0 else { break }
                        pending.append(contentsOf: buffer.prefix(count))
                        while let newline = pending.firstIndex(of: 10) {
                            let line = pending.prefix(upTo: newline); pending.removeSubrange(...newline)
                            guard line.count <= connection.messageLimit else { return }
                            let packet = Data(line)
                            delivery.wait()
                            Task { await receive(connection, packet); delivery.signal() }
                        }
                        if pending.count > connection.messageLimit { return }
                    }
                }
            }
        }
    }
    func stop() {
        lock.lock(); stopped = true; let peers = Array(connections.values); connections.removeAll(); lock.unlock()
        for peer in peers { peer.close() }
        if listener >= 0 { shutdown(listener, SHUT_RDWR); Darwin.close(listener); listener = -1 }
        if ownsSocket { unlink(path); ownsSocket = false }
        if fileLock >= 0 { flock(fileLock, LOCK_UN); Darwin.close(fileLock); fileLock = -1 }
    }
    deinit { stop() }
}
