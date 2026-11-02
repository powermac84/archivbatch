#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
cd "$PROJECT_DIR"

if ! command -v xcrun >/dev/null 2>&1; then
  printf '%s\n' 'Zum Bauen werden die Xcode Command Line Tools benötigt.' >&2
  exit 1
fi
SDK_PATH="$(xcrun --sdk macosx --show-sdk-path)"
SWIFTC_PATH="$(xcrun --find swiftc)"
BUILD_DIR="$PROJECT_DIR/.build"
APP_DIR="$PROJECT_DIR/dist/ArchivBatch.app"
EXECUTABLE_DIR="$APP_DIR/Contents/MacOS"
RESOURCE_DIR="$APP_DIR/Contents/Resources"

for required_file in Vendor/7zz Vendor/License.txt Vendor/History.txt Vendor/readme.txt LICENSES/LGPL-2.1.txt Info.plist Resources/Localization/en.json; do
  if [ ! -f "$required_file" ]; then
    printf 'Erforderliche Datei fehlt: %s\n' "$required_file" >&2
    exit 1
  fi
done
if [ ! -d Vendor/MANUAL ]; then
  printf '%s\n' 'Die 7-Zip-Dokumentation Vendor/MANUAL fehlt.' >&2
  exit 1
fi

mkdir -p "$BUILD_DIR" "$EXECUTABLE_DIR" "$RESOURCE_DIR/7-Zip"

for architecture in arm64 x86_64; do
  printf 'Kompiliere ArchivBatch für %s …\n' "$architecture"
  deployment_version=12.0
  if [ "$architecture" = x86_64 ]; then deployment_version=14.0; fi
  "$SWIFTC_PATH" -O -swift-version 5 -parse-as-library \
    -module-cache-path "$BUILD_DIR/ModuleCache" \
    -sdk "$SDK_PATH" -target "${architecture}-apple-macosx${deployment_version}" \
    -framework SwiftUI -framework AppKit \
    Sources/*.swift -o "$BUILD_DIR/ArchivBatch-$architecture"
done

/usr/bin/lipo -create \
  "$BUILD_DIR/ArchivBatch-arm64" "$BUILD_DIR/ArchivBatch-x86_64" \
  -output "$EXECUTABLE_DIR/ArchivBatch"
/bin/cp -R Resources/Localization "$RESOURCE_DIR/"
/bin/cp Info.plist "$APP_DIR/Contents/Info.plist"
/bin/cp Vendor/7zz "$RESOURCE_DIR/7zz"
/bin/cp Vendor/License.txt Vendor/History.txt Vendor/readme.txt "$RESOURCE_DIR/7-Zip/"
/bin/cp LICENSES/LGPL-2.1.txt "$RESOURCE_DIR/7-Zip/"
/bin/cp -R Vendor/MANUAL "$RESOURCE_DIR/7-Zip/"
/bin/cp Assets/ArchivBatch.icns "$RESOURCE_DIR/ArchivBatch.icns"
/bin/cp README.md "$RESOURCE_DIR/README.md"
/bin/cp LICENSE "$RESOURCE_DIR/LICENSE-ArchivBatch.txt"
/bin/cp THIRD_PARTY_NOTICES.md "$RESOURCE_DIR/THIRD_PARTY_NOTICES.md"
if [ -f Vendor/7z2603-src.7z ]; then
  /bin/cp Vendor/7z2603-src.7z "$RESOURCE_DIR/7-Zip/"
fi
/bin/chmod 755 "$EXECUTABLE_DIR/ArchivBatch" "$RESOURCE_DIR/7zz"

/usr/bin/plutil -lint "$APP_DIR/Contents/Info.plist"
for architecture in arm64 x86_64; do
  /usr/bin/lipo "$EXECUTABLE_DIR/ArchivBatch" -verify_arch "$architecture"
  /usr/bin/lipo "$RESOURCE_DIR/7zz" -verify_arch "$architecture"
done
/usr/bin/codesign --force --sign - --timestamp=none "$RESOURCE_DIR/7zz"
/usr/bin/codesign --force --sign - --timestamp=none "$APP_DIR"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_DIR"

printf '\nFertige App: %s\n' "$APP_DIR"
