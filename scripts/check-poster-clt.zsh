#!/bin/zsh
set -euo pipefail
setopt null_glob
PROJECT_ROOT=${0:A:h:h}
SDK_PATH=${COMPOSITOR_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}
if [[ -z ${COMPOSITOR_SDK_PATH:-} && -d "${SDK_PATH:h}/MacOSX26.sdk" ]]; then
    SDK_PATH="${SDK_PATH:h}/MacOSX26.sdk"
fi
WORK_ROOT=$(mktemp -d /private/tmp/compositor-poster.XXXXXX)
trap 'rm -rf "$WORK_ROOT"' EXIT
mkdir -p "$WORK_ROOT/obj"
for file in "$PROJECT_ROOT"/Compositor/**/*.c; do
    xcrun clang -O2 -std=c11 -target arm64-apple-macosx26.0 -isysroot "$SDK_PATH" \
        "-ffile-prefix-map=$PROJECT_ROOT=." -c "$file" -o "$WORK_ROOT/obj/${file:t:r}.o"
done
cat > "$WORK_ROOT/Run.swift" <<'SWIFT'
import AppKit
@main struct RunPosterChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let index = CommandLine.arguments.firstIndex(of: "--output")
        let folder = index.flatMap { $0 + 1 < CommandLine.arguments.count ? URL(fileURLWithPath: CommandLine.arguments[$0+1]) : nil }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("PosterChecks-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let result = try await PosterRegressionChecks.run(output: folder, large: CommandLine.arguments.contains("--large"))
        print("Poster: \(result.checks) checks, \(result.failures.count) failures")
        for failure in result.failures { print("FAIL: \(failure)") }
        for measurement in result.measurements { print(measurement) }
        if !result.failures.isEmpty { exit(1) }
        let paths = try await PathRegressionChecks.run(output: folder)
        print("Paths and PSD: \(paths.checks) checks, \(paths.failures.count) failures")
        for failure in paths.failures { print("FAIL: \(failure)") }
        if !paths.failures.isEmpty { exit(1) }
        let liquid = try await LiquifyRegressionChecks.run()
        print("Liquify: \(liquid.checks) checks, \(liquid.failures.count) failures")
        for failure in liquid.failures { print("FAIL: \(failure)") }
        let first = try await FirstBatchRegressionChecks.run()
        print("First batch: \(first.checks) checks, \(first.failures.count) failures")
        for failure in first.failures { print("FAIL: \(failure)") }
        let shortcuts = try await ShortcutRegressionChecks.run()
        print("Shortcuts: \(shortcuts.checks) checks, \(shortcuts.failures.count) failures")
        for failure in shortcuts.failures { print("FAIL: \(failure)") }
        if !liquid.failures.isEmpty || !first.failures.isEmpty || !shortcuts.failures.isEmpty { exit(1) }
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
    -D PATH_CLT_CHECKS -D POSTER_CLT_CHECKS -D LIQUIFY_CLT_CHECKS -D FIRST_BATCH_CLT_CHECKS -D SHORTCUT_CLT_CHECKS -parse-as-library -O -whole-module-optimization -num-threads 8 \
    -gnone -file-prefix-map "$PROJECT_ROOT=." \
    -import-objc-header "$PROJECT_ROOT/Compositor/Compositor-Bridging-Header.h" \
    "${sources[@]}" "$PROJECT_ROOT/CompositorTests/LiquifyRegressionTests.swift" "$PROJECT_ROOT/CompositorTests/FirstBatchRegressionTests.swift" "$PROJECT_ROOT/CompositorTests/ShortcutRegressionTests.swift" "$PROJECT_ROOT/CompositorTests/PosterRegressionTests.swift" "$PROJECT_ROOT/CompositorTests/PathRegressionTests.swift" "$WORK_ROOT/Run.swift" \
    "$WORK_ROOT"/obj/*.o -o "$WORK_ROOT/poster-checks"
mkdir -p "$PROJECT_ROOT/build"
cp "$WORK_ROOT/poster-checks" "$PROJECT_ROOT/build/poster-checks"
"$WORK_ROOT/poster-checks" "$@"
