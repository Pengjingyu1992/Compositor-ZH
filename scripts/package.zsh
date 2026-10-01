#!/bin/zsh
set -euo pipefail
PROJECT_ROOT=${0:A:h:h}
APP_PATH=${1:-"$PROJECT_ROOT/build/clt/Compositor.app"}
VERSION=$(plutil -extract CFBundleShortVersionString raw "$APP_PATH/Contents/Info.plist")
BUILD=$(plutil -extract CFBundleVersion raw "$APP_PATH/Contents/Info.plist")
DIST="$PROJECT_ROOT/dist"
mkdir -p "$DIST"
ZIP="$DIST/Compositor-ZH-$VERSION-build$BUILD-macOS-arm64.zip"
# Stage outside synchronized folders so Finder attributes cannot invalidate the signature.
PACKAGE_ROOT=$(mktemp -d /private/tmp/compositor-package.XXXXXX)
trap 'rm -rf "$PACKAGE_ROOT"' EXIT
STAGED_APP="$PACKAGE_ROOT/Compositor.app"
ditto --norsrc --noextattr "$APP_PATH" "$STAGED_APP"
xattr -cr "$STAGED_APP"
codesign --force --sign - --entitlements "$PROJECT_ROOT/Config/Compositor.entitlements" "$STAGED_APP"
codesign --verify --deep --strict "$STAGED_APP"
COPYFILE_DISABLE=1 ditto -c -k --norsrc --noextattr --keepParent "$STAGED_APP" "$ZIP"
cd "$DIST"
shasum -a 256 "${ZIP:t}" > SHA256SUMS.txt
print -r -- "Packaged $ZIP"
