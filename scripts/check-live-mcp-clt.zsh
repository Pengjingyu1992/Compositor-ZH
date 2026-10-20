#!/bin/zsh
set -euo pipefail
setopt null_glob
PROJECT_ROOT=${0:A:h:h}
SDK_PATH=${COMPOSITOR_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}
if [[ -z ${COMPOSITOR_SDK_PATH:-} && -d "${SDK_PATH:h}/MacOSX26.sdk" ]]; then
    SDK_PATH="${SDK_PATH:h}/MacOSX26.sdk"
fi
WORK_ROOT=$(mktemp -d /private/tmp/compositor-live-mcp.XXXXXX)
trap 'rm -rf "$WORK_ROOT"' EXIT
mkdir -p "$WORK_ROOT/obj"
for file in "$PROJECT_ROOT"/Compositor/**/*.c; do
    xcrun clang -O2 -std=c11 -target arm64-apple-macosx26.0 -isysroot "$SDK_PATH" \
        "-ffile-prefix-map=$PROJECT_ROOT=." -c "$file" -o "$WORK_ROOT/obj/${file:t:r}.o"
done
cat > "$WORK_ROOT/Run.swift" <<'SWIFT'
import AppKit
@main struct RunLiveMCPChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        if CommandLine.arguments.contains("--serve") {
            let root = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(".mcp-live")
            let workspace = ProjectWorkspace()
            workspace.current.session.createNewProject(width: 64, height: 48)
            let defaults = UserDefaults(suiteName: "Compositor.LiveMCP.Fixture")!
            let service = MCPLiveService(workspace: workspace, defaults: defaults, root: root, approval: { _, _ in true })
            let registered = try service.addClient(name: "Synthetic Wire Fixture")
            var grant = registered; grant.edit = true; grant.files = true; grant.destructive = true; service.update(grant)
            let output = root.appendingPathComponent("output", isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            try service.setFolder(output)
            service.setEnabled(true)
            guard service.enabled else { throw MCPBridgeError.message(service.error ?? "Fixture startup failed") }
            let metadata: [String: Any] = ["pid": ProcessInfo.processInfo.processIdentifier, "config": root.appendingPathComponent(grant.id.uuidString + ".json").path, "socket": service.socketPath, "output": output.path]
            try JSONSerialization.data(withJSONObject: metadata).write(to: root.appendingPathComponent("fixture.json"), options: [.atomic])
            let deadline = Date().addingTimeInterval(180)
            while Date() < deadline, !FileManager.default.fileExists(atPath: root.appendingPathComponent("stop").path) {
                try await Task.sleep(nanoseconds: 100_000_000)
            }
            service.revoke(grant.id); service.stop(); return
        }
        let result = try await LiveMCPRegressionChecks.run()
        print("Live MCP: \(result.checks) checks, \(result.failures.count) failures")
        for failure in result.failures { print("FAIL: \(failure)") }
        if !result.failures.isEmpty { exit(1) }
    }
}
SWIFT
sources=("$PROJECT_ROOT"/Compositor/**/*.swift)
sources=("${(@)sources:#*/CompositorApp.swift}")
xcrun swiftc -sdk "$SDK_PATH" -target arm64-apple-macosx26.0 -swift-version 5 -default-isolation MainActor \
    -enable-upcoming-feature DisableOutwardActorInference \
    -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature InferSendableFromCaptures \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -D LIVE_MCP_CLT_CHECKS -parse-as-library -O -whole-module-optimization -num-threads 8 \
    -gnone -file-prefix-map "$PROJECT_ROOT=." \
    -import-objc-header "$PROJECT_ROOT/Compositor/Compositor-Bridging-Header.h" \
    "${sources[@]}" "$PROJECT_ROOT/CompositorTests/LiveMCPRegressionTests.swift" "$WORK_ROOT/Run.swift" \
    "$WORK_ROOT"/obj/*.o -o "$WORK_ROOT/live-mcp-checks"
mkdir -p "$PROJECT_ROOT/build"
cp "$WORK_ROOT/live-mcp-checks" "$PROJECT_ROOT/build/live-mcp-checks"
"$WORK_ROOT/live-mcp-checks" "$@"
