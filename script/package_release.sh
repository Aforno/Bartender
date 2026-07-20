#!/usr/bin/env bash
set -euo pipefail

APP_NAME="BarTender"
BUNDLE_ID="io.github.aforno.bartender"
MIN_SYSTEM_VERSION="14.0"
SIGNING_IDENTITY="${BARTENDER_SIGNING_IDENTITY:-}"
NOTARY_PROFILE="${BARTENDER_NOTARY_PROFILE:-}"
NOTARY_KEY_PATH="${BARTENDER_NOTARY_KEY_PATH:-}"
NOTARY_KEY_ID="${BARTENDER_NOTARY_KEY_ID:-}"
NOTARY_ISSUER_ID="${BARTENDER_NOTARY_ISSUER_ID:-}"
ARCH_MODE="universal"
SKIP_NOTARIZATION=false
ADHOC_SIGNING=false

usage() {
  sed -n '2,34p' "$0" | sed -n 's/^# //p'
}

# package_release.sh [options]
#
# Builds the release executable, assembles a complete app bundle, signs it with
# the hardened runtime, creates ZIP and DMG artifacts, notarizes and staples
# both deliverables, and emits SHA-256 checksums.
#
# Options:
#   --signing-identity NAME  Developer ID Application identity.
#   --notary-profile NAME   notarytool keychain profile.
#   --notary-key PATH       App Store Connect API .p8 key.
#   --notary-key-id ID      App Store Connect API key ID.
#   --notary-issuer ID      App Store Connect issuer ID.
#   --arch MODE             universal (default), native, arm64, or x86_64.
#   --adhoc                 Local/CI validation build with an ad-hoc signature.
#   --skip-notarization     Skip notarization and stapling (requires --adhoc).
#   --help                  Show this help.
#
# Environment equivalents use the BARTENDER_ prefix, for example
# BARTENDER_SIGNING_IDENTITY and BARTENDER_NOTARY_PROFILE.

while [[ $# -gt 0 ]]; do
  case "$1" in
    --signing-identity) SIGNING_IDENTITY="${2:?missing identity}"; shift 2 ;;
    --notary-profile) NOTARY_PROFILE="${2:?missing profile}"; shift 2 ;;
    --notary-key) NOTARY_KEY_PATH="${2:?missing key path}"; shift 2 ;;
    --notary-key-id) NOTARY_KEY_ID="${2:?missing key ID}"; shift 2 ;;
    --notary-issuer) NOTARY_ISSUER_ID="${2:?missing issuer ID}"; shift 2 ;;
    --arch) ARCH_MODE="${2:?missing architecture mode}"; shift 2 ;;
    --adhoc) ADHOC_SIGNING=true; shift ;;
    --skip-notarization) SKIP_NOTARIZATION=true; shift ;;
    --help|-h) usage; exit 0 ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; usage >&2; exit 2 ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
[[ -f "$ROOT_DIR/Package.swift" ]] || { printf 'Package.swift not found at %s\n' "$ROOT_DIR" >&2; exit 1; }

VERSION="$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")"
BUILD_NUMBER="$(tr -d '[:space:]' < "$ROOT_DIR/BUILD_NUMBER")"
[[ "$VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || { printf 'Invalid VERSION: %s\n' "$VERSION" >&2; exit 1; }
[[ "$BUILD_NUMBER" =~ ^[1-9][0-9]*$ ]] || { printf 'Invalid BUILD_NUMBER: %s\n' "$BUILD_NUMBER" >&2; exit 1; }

if $SKIP_NOTARIZATION && ! $ADHOC_SIGNING; then
  printf '%s\n' '--skip-notarization is only accepted with --adhoc; distribution artifacts must be notarized.' >&2
  exit 1
fi

if $ADHOC_SIGNING; then
  SIGNING_IDENTITY="-"
else
  [[ "$SIGNING_IDENTITY" == Developer\ ID\ Application:* ]] || {
    printf '%s\n' 'A Developer ID Application identity is required. Use --adhoc only for local/CI verification.' >&2
    exit 1
  }
  if [[ -z "$NOTARY_PROFILE" ]]; then
    [[ -f "$NOTARY_KEY_PATH" && -n "$NOTARY_KEY_ID" && -n "$NOTARY_ISSUER_ID" ]] || {
      printf '%s\n' 'Provide --notary-profile or the complete --notary-key/--notary-key-id/--notary-issuer set.' >&2
      exit 1
    }
  fi
fi

case "$ARCH_MODE" in
  universal) SWIFT_ARCH_ARGS=(--arch arm64 --arch x86_64) ;;
  native) SWIFT_ARCH_ARGS=() ;;
  arm64|x86_64) SWIFT_ARCH_ARGS=(--arch "$ARCH_MODE") ;;
  *) printf 'Unsupported architecture mode: %s\n' "$ARCH_MODE" >&2; exit 2 ;;
esac

BUILD_ROOT="$ROOT_DIR/.build-release"
DIST_ROOT="$ROOT_DIR/dist/release"
APP_BUNDLE="$DIST_ROOT/$APP_NAME.app"
APP_CONTENTS="$APP_BUNDLE/Contents"
APP_BINARY="$APP_CONTENTS/MacOS/$APP_NAME"
INFO_PLIST="$APP_CONTENTS/Info.plist"
RESOURCE_BUNDLE_NAME="BarTender_BarTender.bundle"
ZIP_PATH="$DIST_ROOT/BarTender-$VERSION.zip"
DMG_PATH="$DIST_ROOT/BarTender-$VERSION.dmg"
CHECKSUM_PATH="$DIST_ROOT/SHA256SUMS.txt"

rm -rf "$BUILD_ROOT" "$DIST_ROOT"
mkdir -p "$APP_CONTENTS/MacOS" "$APP_CONTENTS/Resources" "$DIST_ROOT"

cd "$ROOT_DIR"
swift build -c release --scratch-path "$BUILD_ROOT" "${SWIFT_ARCH_ARGS[@]}"
BUILD_BIN_DIR="$(swift build -c release --scratch-path "$BUILD_ROOT" "${SWIFT_ARCH_ARGS[@]}" --show-bin-path)"
[[ -x "$BUILD_BIN_DIR/$APP_NAME" ]] || { printf 'Release executable missing: %s\n' "$BUILD_BIN_DIR/$APP_NAME" >&2; exit 1; }

cp "$BUILD_BIN_DIR/$APP_NAME" "$APP_BINARY"
chmod 755 "$APP_BINARY"

RESOURCE_BUNDLE="$BUILD_BIN_DIR/$RESOURCE_BUNDLE_NAME"
[[ -d "$RESOURCE_BUNDLE" ]] || { printf 'SwiftPM resource bundle missing: %s\n' "$RESOURCE_BUNDLE" >&2; exit 1; }
# AppResources resolves this conventional location in packaged builds. Keeping
# everything below Contents is required for a sealed macOS application bundle.
cp -R "$RESOURCE_BUNDLE" "$APP_CONTENTS/Resources/$RESOURCE_BUNDLE_NAME"

cp "$ROOT_DIR/Packaging/Info.plist" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $BUNDLE_ID" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleShortVersionString $VERSION" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :CFBundleVersion $BUILD_NUMBER" "$INFO_PLIST"
/usr/libexec/PlistBuddy -c "Set :LSMinimumSystemVersion $MIN_SYSTEM_VERSION" "$INFO_PLIST"

PARTIAL_PLIST="$BUILD_ROOT/assetcatalog.plist"
xcrun actool "$ROOT_DIR/Packaging/Assets.xcassets" \
  --compile "$APP_CONTENTS/Resources" \
  --platform macosx \
  --minimum-deployment-target "$MIN_SYSTEM_VERSION" \
  --target-device mac \
  --app-icon AppIcon \
  --development-region en \
  --output-partial-info-plist "$PARTIAL_PLIST" \
  --warnings --notices
/usr/libexec/PlistBuddy -c "Merge $PARTIAL_PLIST" "$INFO_PLIST"

for document in LICENSE CHANGELOG.md PRIVACY.md RELEASE_NOTES.md SECURITY.md SUPPORT.md THIRD_PARTY_NOTICES.md; do
  [[ -f "$ROOT_DIR/$document" ]] && cp "$ROOT_DIR/$document" "$APP_CONTENTS/Resources/$document"
done
cp "$ROOT_DIR/Packaging/provider-icons.json" "$APP_CONTENTS/Resources/provider-icons.json"

if $ADHOC_SIGNING; then
  SIGN_TIMESTAMP_ARGS=(--timestamp=none)
else
  SIGN_TIMESTAMP_ARGS=(--timestamp)
fi

/usr/bin/codesign --force \
  --sign "$SIGNING_IDENTITY" \
  --options runtime \
  "${SIGN_TIMESTAMP_ARGS[@]}" \
  --entitlements "$ROOT_DIR/Packaging/BarTender.entitlements" \
  "$APP_BUNDLE"
/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"

notarize() {
  local artifact="$1"
  if [[ -n "$NOTARY_PROFILE" ]]; then
    xcrun notarytool submit "$artifact" --keychain-profile "$NOTARY_PROFILE" --wait
  else
    xcrun notarytool submit "$artifact" \
      --key "$NOTARY_KEY_PATH" \
      --key-id "$NOTARY_KEY_ID" \
      --issuer "$NOTARY_ISSUER_ID" \
      --wait
  fi
}

/usr/bin/ditto -c -k --keepParent --sequesterRsrc "$APP_BUNDLE" "$ZIP_PATH"
if ! $SKIP_NOTARIZATION; then
  notarize "$ZIP_PATH"
  xcrun stapler staple "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
  rm -f "$ZIP_PATH"
  /usr/bin/ditto -c -k --keepParent --sequesterRsrc "$APP_BUNDLE" "$ZIP_PATH"
fi

DMG_STAGE="$BUILD_ROOT/dmg"
mkdir -p "$DMG_STAGE"
cp -R "$APP_BUNDLE" "$DMG_STAGE/BarTender.app"
ln -s /Applications "$DMG_STAGE/Applications"
/usr/bin/hdiutil create \
  -volname "Bar Tender" \
  -srcfolder "$DMG_STAGE" \
  -format UDZO \
  -ov "$DMG_PATH"

if ! $ADHOC_SIGNING; then
  /usr/bin/codesign --force --sign "$SIGNING_IDENTITY" --timestamp "$DMG_PATH"
fi
if ! $SKIP_NOTARIZATION; then
  notarize "$DMG_PATH"
  xcrun stapler staple "$DMG_PATH"
  xcrun stapler validate "$DMG_PATH"
fi

(
  cd "$DIST_ROOT"
  /usr/bin/shasum -a 256 "$(basename "$ZIP_PATH")" "$(basename "$DMG_PATH")" > "$(basename "$CHECKSUM_PATH")"
)

printf 'Release app: %s\nArchive: %s\nDisk image: %s\nChecksums: %s\n' \
  "$APP_BUNDLE" "$ZIP_PATH" "$DMG_PATH" "$CHECKSUM_PATH"
