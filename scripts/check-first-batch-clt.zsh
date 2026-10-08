#!/bin/zsh
set -euo pipefail
setopt null_glob
PROJECT_ROOT=${0:A:h:h}
SDK_PATH=${COMPOSITOR_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}
if [[ -z ${COMPOSITOR_SDK_PATH:-} && -d "${SDK_PATH:h}/MacOSX26.sdk" ]]; then
    SDK_PATH="${SDK_PATH:h}/MacOSX26.sdk"
fi
WORK_ROOT=$(mktemp -d /private/tmp/compositor-first-batch.XXXXXX)
trap 'rm -rf "$WORK_ROOT"' EXIT
mkdir -p "$WORK_ROOT/obj"
for file in "$PROJECT_ROOT"/Compositor/**/*.c; do
    xcrun clang -O2 -std=c11 -target arm64-apple-macosx26.0 -isysroot "$SDK_PATH" \
        "-ffile-prefix-map=$PROJECT_ROOT=." -c "$file" -o "$WORK_ROOT/obj/${file:t:r}.o"
done
cat > "$WORK_ROOT/Run.swift" <<'SWIFT'
import AppKit
@main struct RunFirstBatchChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        if let index = CommandLine.arguments.firstIndex(of: "--psd"), CommandLine.arguments.count > index + 2 {
            try await FirstBatchRegressionChecks.inspectPSD(CommandLine.arguments[index+1], output: CommandLine.arguments[index+2])
        }
        let result = try await FirstBatchRegressionChecks.run(largeCanvases: CommandLine.arguments.contains("--large"))
        print("First batch: \(result.checks) checks, \(result.failures.count) failures")
        for failure in result.failures { print("FAIL: \(failure)") }
        for measurement in result.measurements { print(measurement) }
        if !result.failures.isEmpty { exit(1) }
        if CommandLine.arguments.contains("--shortcuts") {
            let shortcuts = try await ShortcutRegressionChecks.run()
            print("Shortcut regression: \(shortcuts.checks) checks, \(shortcuts.failures.count) failures")
            for failure in shortcuts.failures { print("FAIL: \(failure)") }
            if !shortcuts.failures.isEmpty { exit(1) }
        }
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
    -D FIRST_BATCH_CLT_CHECKS -D SHORTCUT_CLT_CHECKS -parse-as-library -O -whole-module-optimization -num-threads 8 \
    -gnone -file-prefix-map "$PROJECT_ROOT=." \
    -import-objc-header "$PROJECT_ROOT/Compositor/Compositor-Bridging-Header.h" \
    "${sources[@]}" "$PROJECT_ROOT/CompositorTests/FirstBatchRegressionTests.swift" "$PROJECT_ROOT/CompositorTests/ShortcutRegressionTests.swift" "$WORK_ROOT/Run.swift" \
    "$WORK_ROOT"/obj/*.o -o "$WORK_ROOT/first-batch-checks"
mkdir -p "$PROJECT_ROOT/build"
cp "$WORK_ROOT/first-batch-checks" "$PROJECT_ROOT/build/first-batch-checks"
"$WORK_ROOT/first-batch-checks" "$@"
