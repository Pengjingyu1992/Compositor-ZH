import Foundation
import Darwin

/// This helper is a transport proxy. It never opens a second document or falls back to standalone editing.
nonisolated enum MCPLiveCLI {
    static func run(configURL: URL) throws {
        var status = stat()
        guard lstat(configURL.path, &status) == 0, status.st_uid == getuid(), status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & 0o077 == 0, status.st_size <= 8192 else { throw MCPBridgeError.message("Select a private live-client configuration created in the app.") }
        let fdConfig = Darwin.open(configURL.path, O_RDONLY | O_NOFOLLOW)
        guard fdConfig >= 0 else { throw MCPBridgeError.message("Unable to read the live-client configuration.") }
        guard fstat(fdConfig, &status) == 0, status.st_uid == getuid(), status.st_mode & S_IFMT == S_IFREG,
              status.st_mode & 0o077 == 0, status.st_size <= 8192 else { Darwin.close(fdConfig); throw MCPBridgeError.message("Invalid private client configuration.") }
        let file = FileHandle(fileDescriptor: fdConfig, closeOnDealloc: true)
        let data = try file.readToEnd() ?? Data(); try file.close()
        guard data.count <= 8192, let config = try JSONSerialization.jsonObject(with: data) as? [String: String],
              let id = config["clientID"], UUID(uuidString: id) != nil, let raw = config["secret"], let secret = Data(base64Encoded: raw), secret.count == 32,
              let path = config["socket"], path.utf8.count < 104 else { throw MCPBridgeError.message("Invalid live-client configuration.") }
        guard lstat(path, &status) == 0, status.st_uid == getuid(), status.st_mode & S_IFMT == S_IFSOCK, status.st_mode & 0o077 == 0 else {
            throw MCPBridgeError.message("The live bridge is unavailable. Open Compositor and enable the connection in Settings. No standalone fallback was used.")
        }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw MCPBridgeError.message("Unable to connect to the live bridge.") }
        defer { Darwin.close(fd) }
        var yes: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &yes, socklen_t(MemoryLayout<Int32>.size))
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        var address = sockaddr_un(); address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: Array(path.utf8) + [0]) }
        let result = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) } }
        guard result == 0 else { throw MCPBridgeError.message("The application bridge is not running. No standalone fallback was used.") }
        var uid: uid_t = 0, gid: gid_t = 0
        guard getpeereid(fd, &uid, &gid) == 0, uid == getuid() else { throw MCPBridgeError.message("Unexpected bridge owner.") }
        let challenge = try readObject(fd)
        guard let nonce = challenge["challenge"] as? String, nonce.count <= 128, let instance = challenge["instance"] as? String,
              UUID(uuidString: instance) != nil else { throw MCPBridgeError.message("Invalid bridge authentication challenge.") }
        let clientNonce = UUID().uuidString
        let binding = nonce + "\n" + clientNonce
        let auth: [String: Any] = ["clientID": id, "clientNonce": clientNonce,
            "proof": MCPBridgeAuth.proof(secret: secret, challenge: binding, instance: instance, role: "client")]
        try writeAll(fd, try JSONSerialization.data(withJSONObject: auth) + Data([10]))
        let response = try readObject(fd)
        guard response["authenticated"] as? Bool == true, let proof = response["proof"] as? String,
              MCPBridgeAuth.matches(proof, MCPBridgeAuth.proof(secret: secret, challenge: binding, instance: instance, role: "server")) else {
            throw MCPBridgeError.message("The client or bridge is not authenticated. Recreate the client configuration in Settings.")
        }
        timeout.tv_sec = 0; setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        signal(SIGPIPE, SIG_IGN)
        // A socket close wakes the input poll; no blocked stdin thread keeps a disconnected helper alive.
        var fds = [pollfd(fd: STDIN_FILENO, events: Int16(POLLIN), revents: 0), pollfd(fd: fd, events: Int16(POLLIN), revents: 0)]
        var buffer = [UInt8](repeating: 0, count: 65536)
        while true {
            let count = poll(&fds, 2, -1)
            if count < 0 && errno == EINTR { continue }
            guard count > 0 else { throw MCPBridgeError.message("Live bridge I/O failed.") }
            if fds[1].revents & Int16(POLLIN) != 0 {
                let n = Darwin.read(fd, &buffer, buffer.count)
                guard n > 0 else { return }
                try writeAll(STDOUT_FILENO, Data(buffer.prefix(n)))
            }
            if fds[1].revents & Int16(POLLHUP | POLLERR | POLLNVAL) != 0 { return }
            if fds[0].revents & Int16(POLLIN | POLLHUP) != 0 {
                let n = Darwin.read(STDIN_FILENO, &buffer, buffer.count)
                guard n > 0 else { return }
                try writeAll(fd, Data(buffer.prefix(n)))
            }
        }
    }
    private static func writeAll(_ fd: Int32, _ data: Data) throws {
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < data.count {
                let count = Darwin.write(fd, bytes.baseAddress! + offset, data.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw MCPBridgeError.message("Live bridge disconnected.") }
                offset += count
            }
        }
    }
    private static func readObject(_ fd: Int32) throws -> [String: Any] {
        var data = Data(), byte: UInt8 = 0
        while data.count < 8192 {
            let count = Darwin.read(fd, &byte, 1)
            if count < 0 && errno == EINTR { continue }
            guard count == 1 else { throw MCPBridgeError.message("Live authentication timed out or disconnected.") }
            if byte == 10 {
                guard let value = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { break }
                return value
            }
            data.append(byte)
        }
        throw MCPBridgeError.message("Invalid live authentication message.")
    }
}
