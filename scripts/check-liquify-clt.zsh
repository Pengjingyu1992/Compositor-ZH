#!/bin/zsh
set -euo pipefail
setopt null_glob
PROJECT_ROOT=${0:A:h:h}
SDK_PATH=${COMPOSITOR_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}
if [[ -z ${COMPOSITOR_SDK_PATH:-} && -d "${SDK_PATH:h}/MacOSX26.sdk" ]]; then
    SDK_PATH="${SDK_PATH:h}/MacOSX26.sdk"
fi
WORK_ROOT=$(mktemp -d /private/tmp/compositor-liquify.XXXXXX)
trap 'rm -rf "$WORK_ROOT"' EXIT
mkdir -p "$WORK_ROOT/obj"
for file in "$PROJECT_ROOT"/Compositor/**/*.c; do
    xcrun clang -O2 -std=c11 -target arm64-apple-macosx26.0 -isysroot "$SDK_PATH" \
        "-ffile-prefix-map=$PROJECT_ROOT=." -c "$file" -o "$WORK_ROOT/obj/${file:t:r}.o"
done
cat > "$WORK_ROOT/Run.swift" <<'SWIFT'
import AppKit
@main struct RunLiquifyChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let outIndex = CommandLine.arguments.firstIndex(of: "--output")
        let output = outIndex.flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0+1] : nil }
        let result = try await LiquifyRegressionChecks.run(large: CommandLine.arguments.contains("--large"), output: output)
        print("Liquify: \(result.checks) checks, \(result.failures.count) failures")
        for failure in result.failures { print("FAIL: \(failure)") }
        for measurement in result.measurements { print(measurement) }
        if !result.failures.isEmpty { exit(1) }
        if CommandLine.arguments.contains("--shortcuts") {
            let baseline = try await FirstBatchRegressionChecks.run()
            print("First batch: \(baseline.checks) checks, \(baseline.failures.count) failures")
            if !baseline.failures.isEmpty { exit(1) }
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
    -D LIQUIFY_CLT_CHECKS -D FIRST_BATCH_CLT_CHECKS -D SHORTCUT_CLT_CHECKS -parse-as-library -O -whole-module-optimization -num-threads 8 \
    -gnone -file-prefix-map "$PROJECT_ROOT=." \
    -import-objc-header "$PROJECT_ROOT/Compositor/Compositor-Bridging-Header.h" \
    "${sources[@]}" "$PROJECT_ROOT/CompositorTests/LiquifyRegressionTests.swift" "$PROJECT_ROOT/CompositorTests/FirstBatchRegressionTests.swift" "$PROJECT_ROOT/CompositorTests/ShortcutRegressionTests.swift" "$WORK_ROOT/Run.swift" \
    "$WORK_ROOT"/obj/*.o -o "$WORK_ROOT/liquify-checks"
mkdir -p "$PROJECT_ROOT/build"
cp "$WORK_ROOT/liquify-checks" "$PROJECT_ROOT/build/liquify-checks"
"$WORK_ROOT/liquify-checks" "$@"
