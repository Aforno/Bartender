#!/usr/bin/env bash
set -euo pipefail

MODE="${1:-run}"
APP_NAME="BarTender"
BUNDLE_ID="io.github.aforno.bartender"
MIN_SYSTEM_VERSION="26.0"

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DIST_DIR="$ROOT_DIR/dist"
APP_BUNDLE="$DIST_DIR/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_MACOS="$APP_CONTENTS/MacOS"
APP_BINARY="$APP_MACOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
APP_RESOURCES="$APP_CONTENTS/Resources"
VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
BUILD_NUMBER="$(tr -d '[:space:]' < "$ROOT_DIR/BUILD_NUMBER")"

pkill -x "$APP_NAME" >/dev/null 2>&1 || true

cd "$ROOT_DIR"
swift build -c debug
BUILD_DIR="$(swift build -c debug --show-bin-path)"
BUILD_BINARY="$BUILD_DIR/$APP_NAME"

rm -rf "$APP_BUNDLE"
mkdir -p "$APP_MACOS" "$APP_RESOURCES"
cp "$BUILD_BINARY" "$APP_BINARY"
chmod +x "$APP_BINARY"

RESOURCE_BUNDLE="$BUILD_DIR/${APP_NAME}_${APP_NAME}.bundle"
[[ -d "$RESOURCE_BUNDLE" ]] || { printf 'Missing SwiftPM resource bundle: %s\n' "$RESOURCE_BUNDLE" >&2; exit 1; }
cp -R "$RESOURCE_BUNDLE" "$APP_RESOURCES/"

cp "$ROOT_DIR/Packaging/Info.plist" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST"

PARTIAL_PLIST="$DIST_DIR/assetcatalog.plist"
xcrun actool "$ROOT_DIR/Packaging/Assets.xcassets" \
  --compile "$APP_RESOURCES" \
  --platform macosx \
  --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
  --target-device mac \
  --app-icon AppIcon \
  --development-region en \
  --output-partial-info-plist "$PARTIAL_PLIST" \
  --warnings --notices >/dev/null
/usr/libexec/PlistBuddy -c "Merge $PARTIAL_PLIST" "$INFO_PLIST"

# Seal the assembled development bundle so resource changes cannot leave it in
# the invalid partially-signed state that Gatekeeper and Launch Services reject.
/usr/bin/codesign --force --sign - --timestamp=none "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict "$APP_BUNDLE"

open_app() {
  /usr/bin/open -n "$APP_BUNDLE"
}

case "$MODE" in
  run)
    open_app
    ;;
  --debug|debug)
    lldb -- "$APP_BINARY"
    ;;
  --logs|logs)
    open_app
    /usr/bin/log stream --info --style compact --predicate "process == \"$APP_NAME\""
    ;;
  --telemetry|telemetry)
    open_app
    /usr/bin/log stream --info --style compact --predicate "subsystem == \"$BUNDLE_ID\""
    ;;
  --verify|verify)
    open_app
    sleep 1
    pgrep -x "$APP_NAME" >/dev/null
    ;;
  *)
    echo "usage: $0 [run|--debug|--logs|--telemetry|--verify]" >&2
    exit 2
    ;;
esac
