#!/bin/zsh
set -euo pipefail
PROJECT_ROOT=${0:A:h:h}
mkdir -p "$PROJECT_ROOT/build"
python3 "$PROJECT_ROOT/scripts/check-localization.py" --check
xcrun swiftc -parse-as-library "$PROJECT_ROOT/Compositor/Localization.swift" \
    "$PROJECT_ROOT/scripts/CheckCatalog.swift" -o "$PROJECT_ROOT/build/check-catalog"
"$PROJECT_ROOT/build/check-catalog" "$PROJECT_ROOT/Compositor/Localizable.xcstrings" \
    "$PROJECT_ROOT/Compositor/InfoPlist.xcstrings"
