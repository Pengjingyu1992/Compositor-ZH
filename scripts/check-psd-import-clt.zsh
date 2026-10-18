#!/bin/zsh
set -euo pipefail
setopt null_glob
PROJECT_ROOT=${0:A:h:h}
SDK_PATH=${COMPOSITOR_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}
if [[ -z ${COMPOSITOR_SDK_PATH:-} && -d "${SDK_PATH:h}/MacOSX26.sdk" ]]; then
    SDK_PATH="${SDK_PATH:h}/MacOSX26.sdk"
fi
WORK_ROOT=$(mktemp -d /private/tmp/compositor-psd-check.XXXXXX)
trap 'rm -rf "$WORK_ROOT"' EXIT
OUTPUT_ROOT="$PROJECT_ROOT/build/psd-import-checks"
mkdir -p "$WORK_ROOT/obj" "$OUTPUT_ROOT"
python3 "$PROJECT_ROOT/scripts/make-psd-import-fixtures.py" "$WORK_ROOT/fixtures"
for file in "$PROJECT_ROOT"/Compositor/**/*.c; do
    xcrun clang -O2 -std=c11 -target arm64-apple-macosx26.0 -isysroot "$SDK_PATH" \
        "-ffile-prefix-map=$PROJECT_ROOT=." -c "$file" -o "$WORK_ROOT/obj/${file:t:r}.o"
done
cat > "$WORK_ROOT/Run.swift" <<'SWIFT'
import AppKit
@main struct RunPSDImportChecks {
    @MainActor static func main() async throws {
        _ = NSApplication.shared
        let args = CommandLine.arguments
        let result = try await PSDImportRegressionChecks.run(fixtures: URL(fileURLWithPath: args[1]),
            output: URL(fileURLWithPath: args[2]), realFile: args.count > 3 ? URL(fileURLWithPath: args[3]) : nil)
        print("PSD import: \(result.checks) checks, \(result.failures.count) failures")
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
    -D PSD_IMPORT_CLT_CHECKS -parse-as-library -O -whole-module-optimization -num-threads 8 \
    -gnone -file-prefix-map "$PROJECT_ROOT=." \
    -import-objc-header "$PROJECT_ROOT/Compositor/Compositor-Bridging-Header.h" \
    "${sources[@]}" "$PROJECT_ROOT/CompositorTests/PSDImportRegressionTests.swift" "$WORK_ROOT/Run.swift" \
    "$WORK_ROOT"/obj/*.o -o "$WORK_ROOT/psd-import-checks"
"$WORK_ROOT/psd-import-checks" "$WORK_ROOT/fixtures" "$OUTPUT_ROOT" "$@"
