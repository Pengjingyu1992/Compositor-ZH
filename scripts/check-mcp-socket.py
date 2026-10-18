"""Check local Unix IPC with an isolated, signed App Sandbox prototype."""
import json
import os
from pathlib import Path
import plistlib
import secrets
import socket
import stat
import subprocess
import tempfile
import time

SOURCE = r'''
import AppKit
import Darwin

@main struct SocketProbe {
    static func main() throws {
        _ = NSApplication.shared
        let nonce = CommandLine.arguments.last!
        guard nonce.count == 12, nonce.allSatisfy({ $0.isHexDigit }) else { throw NSError(domain: "MCPSocketProbe", code: 2) }
        let directory = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".mcp-probe-" + nonce)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false,
                                               attributes: [.posixPermissions: 0o700])
        let endpoint = directory.appendingPathComponent("s")
        defer { try? FileManager.default.removeItem(at: directory) }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { throw NSError(domain: "MCPSocketProbe", code: 3) }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        let path = Array(endpoint.path.utf8) + [UInt8(0)]
        guard path.count <= MemoryLayout.size(ofValue: address.sun_path) else { throw NSError(domain: "MCPSocketProbe", code: 4) }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.copyBytes(from: path)
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, chmod(endpoint.path, 0o600) == 0, listen(fd, 1) == 0 else { throw NSError(domain: "MCPSocketProbe", code: 5) }
        let ready = try JSONSerialization.data(withJSONObject: ["path": endpoint.path, "uid": getuid()])
        try ready.write(to: directory.appendingPathComponent("ready.json"), options: .atomic)
        var event = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
        guard poll(&event, 1, 15000) == 1 else { throw NSError(domain: "MCPSocketProbe", code: 6) }
        let peer = accept(fd, nil, nil)
        guard peer >= 0 else { throw NSError(domain: "MCPSocketProbe", code: 7) }
        defer { close(peer) }
        var peerUID = uid_t(), peerGID = gid_t()
        guard getpeereid(peer, &peerUID, &peerGID) == 0, peerUID == getuid() else { throw NSError(domain: "MCPSocketProbe", code: 8) }
        var payload = [UInt8](repeating: 0, count: 64)
        var readEvent = pollfd(fd: peer, events: Int16(POLLIN), revents: 0)
        guard poll(&readEvent, 1, 5000) == 1 else { throw NSError(domain: "MCPSocketProbe", code: 9) }
        let count = read(peer, &payload, payload.count)
        guard count > 0, String(decoding: payload.prefix(count), as: UTF8.self) == nonce else { throw NSError(domain: "MCPSocketProbe", code: 10) }
        let response = Array("{\"ok\":true}\n".utf8)
        guard response.withUnsafeBytes({ write(peer, $0.baseAddress, response.count) }) == response.count else { throw NSError(domain: "MCPSocketProbe", code: 11) }
    }
}
'''


def run():
    nonce = secrets.token_hex(6)
    bundle_id = "compositor.mcp-probe"
    container = Path.home() / "Library/Containers" / bundle_id / "Data"
    directory = container / (".mcp-probe-" + nonce)
    # Darwin pathname sockets include a terminating NUL in the 104-byte sun_path.
    if len(os.fsencode(directory / "s")) >= 104:
        raise RuntimeError("The container socket path exceeds Darwin's pathname limit.")
    with tempfile.TemporaryDirectory(prefix="compositor-mcp-socket-", dir="/private/tmp") as scratch:
        scratch = Path(scratch)
        app = scratch / "MCPSocketProbe.app"
        executable = app / "Contents/MacOS/MCPSocketProbe"
        executable.parent.mkdir(parents=True)
        source = scratch / "Probe.swift"
        source.write_text(SOURCE)
        sdk = subprocess.check_output(["xcrun", "--sdk", "macosx", "--show-sdk-path"], text=True).strip()
        subprocess.run(["xcrun", "swiftc", "-parse-as-library", "-sdk", sdk,
                        str(source), "-o", str(executable)], check=True, capture_output=True, text=True)
        info = {"CFBundleIdentifier": bundle_id, "CFBundleExecutable": "MCPSocketProbe",
                "CFBundleName": "MCP Socket Probe", "CFBundlePackageType": "APPL", "LSUIElement": True}
        with (app / "Contents/Info.plist").open("wb") as handle:
            plistlib.dump(info, handle)
        entitlements = scratch / "Probe.entitlements"
        with entitlements.open("wb") as handle:
            plistlib.dump({"com.apple.security.app-sandbox": True}, handle)
        subprocess.run(["codesign", "--force", "--sign", "-", "--entitlements", str(entitlements), str(app)],
                       check=True, capture_output=True, text=True)
        subprocess.run(["codesign", "--verify", "--deep", "--strict", str(app)], check=True)
        launcher = subprocess.Popen(["open", "-W", "-n", str(app), "--args", nonce],
                                    stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True)
        try:
            deadline = time.monotonic() + 12
            ready = directory / "ready.json"
            while not ready.exists() and time.monotonic() < deadline:
                if launcher.poll() is not None:
                    raise RuntimeError("Sandbox prototype exited before publishing its socket.")
                time.sleep(0.1)
            if not ready.exists():
                raise RuntimeError("Sandbox prototype did not become ready within 12 seconds.")
            state = json.loads(ready.read_text())
            endpoint = Path(state["path"])
            if endpoint != directory / "s" or state["uid"] != os.getuid():
                raise RuntimeError("Unexpected endpoint or user identity.")
            if stat.S_IMODE(directory.stat().st_mode) != 0o700:
                raise RuntimeError("Endpoint directory permissions are not 0700.")
            if stat.S_IMODE(endpoint.stat().st_mode) != 0o600:
                raise RuntimeError("Socket permissions are not 0600.")
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
                client.settimeout(5)
                client.connect(str(endpoint))
                client.sendall(nonce.encode())
                response = b""
                while not response.endswith(b"\n"):
                    chunk = client.recv(64)
                    if not chunk:
                        raise RuntimeError("Endpoint closed before returning a complete response.")
                    response += chunk
                    if len(response) > 128:
                        raise RuntimeError("Unexpected response size.")
                if json.loads(response) != {"ok": True}:
                    raise RuntimeError("Unexpected response.")
            if launcher.wait(timeout=8) != 0:
                raise RuntimeError("Sandbox prototype launch failed.")
            if directory.exists():
                raise RuntimeError("Prototype did not clean its endpoint after shutdown.")
            print("Signed sandbox prototype: AF_UNIX round trip, peer UID, 0700/0600 and cleanup passed.")
            print("This validates transport feasibility; the editor's live Host and authorization remain unimplemented.")
        finally:
            if launcher.poll() is None:
                try:
                    launcher.wait(timeout=20)
                except subprocess.TimeoutExpired:
                    launcher.terminate()
                    launcher.wait(timeout=5)


if __name__ == "__main__":
    try:
        run()
    except subprocess.CalledProcessError as error:
        print(error.stderr or str(error))
        raise SystemExit(1)
