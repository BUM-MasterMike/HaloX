#!/bin/bash
#
# build.sh – builds the native HaloXBuilder.app into the repo root.
#
# Copyright (c) 2026 BUM MasterMike. Licensed under the MIT License.
# See the LICENSE file for details.
#
# It compiles HaloXBuilder.swift with swiftc, bundles the shield
# icon from assets/shield.icns as the app icon, and writes an
# Info.plist with the org.bum.haloxbuilder identifier. The app is
# opened at the end so it can be used right away.
#
# Architecture: the app is built as a universal (arm64 + x86_64) binary
# by default, so the same bundle runs natively on Apple Silicon and
# Intel Macs. Override with ARCH=arm64 or ARCH=x86_64 for a single arch:
#
#   ./ui/build.sh            # universal (default)
#   ARCH=arm64 ./ui/build.sh # arm64 only
#   ARCH=x86_64 ./ui/build.sh # Intel only
#
# HaloXBuilder.swift resolves the default --arch at compile time
# (#if arch(arm64)), so each slice picks the right default popup entry
# on its own platform.
#

set -e

cd "$(dirname "$0")"
ROOT="$(cd .. && pwd)"

# App version: same as HaloX, read from the topmost "## [x.y.z]" section of
# CHANGELOG.md (the single source of truth, exactly like the CI workflows).
VERSION="$(sed -nE 's/^## \[([0-9]+\.[0-9]+\.[0-9]+)\].*/\1/p' "$ROOT/CHANGELOG.md" | head -1)"
if [ -z "$VERSION" ]; then
    echo "Could not read version from CHANGELOG.md (expected a '## [x.y.z]' heading)." >&2
    exit 1
fi

APP="$ROOT/HaloXBuilder.app"
CONTENTS="$APP/Contents"

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS" "$CONTENTS/Resources"

# Architecture: universal (arm64 + x86_64) by default; override with ARCH.
ARCH="${ARCH:-universal}"

compile_slice () {
    local target="$1" out="$2"
    swiftc -O \
        -target "$target" \
        -framework AppKit \
        HaloXBuilder.swift \
        -o "$out"
}

case "$ARCH" in
    universal)
        compile_slice arm64-apple-macos11.0 "$CONTENTS/MacOS/HaloXBuilder.arm64"
        compile_slice x86_64-apple-macos11.0 "$CONTENTS/MacOS/HaloXBuilder.x86_64"
        lipo -create -output "$CONTENTS/MacOS/HaloXBuilder" \
            "$CONTENTS/MacOS/HaloXBuilder.arm64" \
            "$CONTENTS/MacOS/HaloXBuilder.x86_64"
        rm -f "$CONTENTS/MacOS/HaloXBuilder.arm64" "$CONTENTS/MacOS/HaloXBuilder.x86_64"
        ;;
    arm64)
        compile_slice arm64-apple-macos11.0 "$CONTENTS/MacOS/HaloXBuilder"
        ;;
    x86_64)
        compile_slice x86_64-apple-macos11.0 "$CONTENTS/MacOS/HaloXBuilder"
        ;;
    *)
        echo "Unknown ARCH: $ARCH (use universal, arm64, or x86_64)" >&2
        exit 1
        ;;
esac

# The builder's own icon: the shield logo from the repo assets.
cp "$ROOT/assets/shield.icns" "$CONTENTS/Resources/AppIcon.icns"

cat > "$CONTENTS/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleExecutable</key>
    <string>HaloXBuilder</string>
    <key>CFBundleIdentifier</key>
    <string>org.bum.haloxbuilder</string>
    <key>CFBundleName</key>
    <string>HaloX Builder</string>
    <key>CFBundlePackageType</key>
    <string>APPL</string>
    <key>CFBundleVersion</key>
    <string>${VERSION}</string>
    <key>CFBundleShortVersionString</key>
    <string>${VERSION}</string>
    <key>BuildDate</key>
    <string>$(date +%Y-%m-%d)</string>
    <key>NSHumanReadableCopyright</key>
    <string>Copyright © 2026 BUM MasterMike.&#10;Licensed under the MIT License.</string>
    <key>CFBundleIconFile</key>
    <string>AppIcon.icns</string>
    <key>NSHighResolutionCapable</key>
    <true/>
    <key>LSMinimumSystemVersion</key>
    <string>11.0</string>
</dict>
</plist>
PLIST

echo "Built: $APP"
# Auto-open only for a local build; skip on CI (no GUI session there).
if [ -z "${CI:-}" ]; then
    open "$APP"
fi
