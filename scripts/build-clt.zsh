#!/bin/zsh
set -euo pipefail
setopt null_glob

PROJECT_ROOT=${0:A:h:h}
BUILD_ROOT="$PROJECT_ROOT/build/clt"
SDK_PATH=${COMPOSITOR_SDK_PATH:-$(xcrun --sdk macosx --show-sdk-path)}
# The standalone macOS 27 CLT SDK needs SwiftUI macro plugins supplied by full Xcode.
if [[ -z ${COMPOSITOR_SDK_PATH:-} && -d "${SDK_PATH:h}/MacOSX26.sdk" ]]; then
    SDK_PATH="${SDK_PATH:h}/MacOSX26.sdk"
fi
APP_PATH="$BUILD_ROOT/Compositor.app"
mkdir -p "$BUILD_ROOT/obj" "$APP_PATH/Contents/MacOS" "$APP_PATH/Contents/Resources"

for file in "$PROJECT_ROOT"/Compositor/**/*.c; do
    xcrun clang -O2 -std=c11 -target arm64-apple-macosx26.0 -isysroot "$SDK_PATH" \
        "-ffile-prefix-map=$PROJECT_ROOT=." -c "$file" -o "$BUILD_ROOT/obj/${file:t:r}.o"
done
xcrun swiftc -sdk "$SDK_PATH" -target arm64-apple-macosx26.0 -swift-version 5 -default-isolation MainActor \
    -enable-upcoming-feature DisableOutwardActorInference \
    -enable-upcoming-feature GlobalActorIsolatedTypesUsability \
    -enable-upcoming-feature InferIsolatedConformances \
    -enable-upcoming-feature InferSendableFromCaptures \
    -enable-upcoming-feature NonisolatedNonsendingByDefault \
    -parse-as-library -O -whole-module-optimization -num-threads 8 -module-name Compositor \
    -gnone -file-prefix-map "$PROJECT_ROOT=." \
    -import-objc-header "$PROJECT_ROOT/Compositor/Compositor-Bridging-Header.h" \
    "$PROJECT_ROOT"/Compositor/**/*.swift "$BUILD_ROOT"/obj/*.o \
    -o "$APP_PATH/Contents/MacOS/Compositor"
python3 "$PROJECT_ROOT/scripts/prepare-resources.py" "$APP_PATH"
xattr -cr "$APP_PATH"
codesign --force --sign - --entitlements "$PROJECT_ROOT/Config/Compositor.entitlements" "$APP_PATH"
codesign --verify --deep --strict "$APP_PATH"
print -r -- "Built $APP_PATH"
