#!/bin/zsh
set -euo pipefail
setopt null_glob
PROJECT_ROOT=${0:A:h:h}
SDK_PATH=${COMPOSITOR_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}
if [[ -z ${COMPOSITOR_SDK_PATH:-} && -d "${SDK_PATH:h}/MacOSX26.sdk" ]]; then
    SDK_PATH="${SDK_PATH:h}/MacOSX26.sdk"
fi
WORK_ROOT=$(mktemp -d /private/tmp/compositor-editable-recovery.XXXXXX)
trap 'rm -rf "$WORK_ROOT"' EXIT
mkdir -p "$WORK_ROOT/obj"
for file in "$PROJECT_ROOT"/Compositor/**/*.c; do
    xcrun clang -O2 -std=c11 -target arm64-apple-macosx26.0 -isysroot "$SDK_PATH" \
        "-ffile-prefix-map=$PROJECT_ROOT=." -c "$file" -o "$WORK_ROOT/obj/${file:t:r}.o"
done
cat > "$WORK_ROOT/Run.swift" <<'SWIFT'
import AppKit
@main struct RunEditableRecoveryChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        if let index = CommandLine.arguments.firstIndex(of: "--crash-writer") {
            try await EditableRecoveryRegressionChecks.crashWriter(URL(fileURLWithPath: CommandLine.arguments[index + 1]))
            return
        }
        if CommandLine.arguments.contains("--save-stress") {
            let result = try await EditableRecoveryRegressionChecks.repeatedNativeSaves()
            print("Native save stress: \(result.checks) checks, \(result.failures.count) failures")
            if !result.failures.isEmpty { exit(1) }
            return
        }
        let index = CommandLine.arguments.firstIndex(of: "--output")
        let output = index.map { URL(fileURLWithPath: CommandLine.arguments[$0 + 1]) }
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("editable-recovery-output")
        let result = try await EditableRecoveryRegressionChecks.run(output: output,
            large: CommandLine.arguments.contains("--large"), crash: CommandLine.arguments.contains("--crash"))
        print("Editable filters and recovery: \(result.checks) checks, \(result.failures.count) failures")
        for measurement in result.measurements { print(measurement) }
        let liquify = try await LiquifyRegressionChecks.run(large: CommandLine.arguments.contains("--large"))
        print("Liquify: \(liquify.checks) checks, \(liquify.failures.count) failures")
        for measurement in liquify.measurements { print(measurement) }
        let baseline = try await FirstBatchRegressionChecks.run()
        print("First batch: \(baseline.checks) checks, \(baseline.failures.count) failures")
        let shortcuts = try await ShortcutRegressionChecks.run()
        print("Shortcuts: \(shortcuts.checks) checks, \(shortcuts.failures.count) failures")
        for failure in liquify.failures + baseline.failures + shortcuts.failures { print("FAIL: \(failure)") }
        if CommandLine.arguments.contains("--poster") {
            let poster = try await PosterRegressionChecks.run(output: output)
            print("Poster: \(poster.checks) checks, \(poster.failures.count) failures")
            let paths = try await PathRegressionChecks.run(output: output)
            print("Paths and PSD: \(paths.checks) checks, \(paths.failures.count) failures")
            for failure in poster.failures + paths.failures { print("FAIL: \(failure)") }
            if !(poster.failures + paths.failures).isEmpty { exit(1) }
        }
        if !(result.failures + liquify.failures + baseline.failures + shortcuts.failures).isEmpty { exit(1) }
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
    -D PATH_CLT_CHECKS -D POSTER_CLT_CHECKS -D EDITABLE_RECOVERY_CLT_CHECKS -D LIQUIFY_CLT_CHECKS -D FIRST_BATCH_CLT_CHECKS -D SHORTCUT_CLT_CHECKS -parse-as-library -O -whole-module-optimization -num-threads 8 \
    -gnone -file-prefix-map "$PROJECT_ROOT=." \
    -import-objc-header "$PROJECT_ROOT/Compositor/Compositor-Bridging-Header.h" \
    "${sources[@]}" "$PROJECT_ROOT/CompositorTests/EditableRecoveryRegressionTests.swift" "$PROJECT_ROOT/CompositorTests/LiquifyRegressionTests.swift" "$PROJECT_ROOT/CompositorTests/FirstBatchRegressionTests.swift" "$PROJECT_ROOT/CompositorTests/ShortcutRegressionTests.swift" "$PROJECT_ROOT/CompositorTests/PosterRegressionTests.swift" "$PROJECT_ROOT/CompositorTests/PathRegressionTests.swift" "$PROJECT_ROOT/CompositorTests/PSDFixture.swift" "$WORK_ROOT/Run.swift" \
    "$WORK_ROOT"/obj/*.o -o "$WORK_ROOT/editable-recovery-checks"
mkdir -p "$PROJECT_ROOT/build"
cp "$WORK_ROOT/editable-recovery-checks" "$PROJECT_ROOT/build/editable-recovery-checks"
/usr/bin/time -l "$WORK_ROOT/editable-recovery-checks" "$@"
