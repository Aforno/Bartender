#!/usr/bin/env bash
set -euo pipefail

DISTRIBUTION=false
APP_BUNDLE=""
DMG_PATH=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --distribution) DISTRIBUTION=true; shift ;;
    --app) APP_BUNDLE="${2:?missing app path}"; shift 2 ;;
    --dmg) DMG_PATH="${2:?missing DMG path}"; shift 2 ;;
    --help|-h)
      printf '%s\n' 'verify_release.sh --app PATH [--dmg PATH] [--distribution]'
      exit 0
      ;;
    *) printf 'Unknown option: %s\n' "$1" >&2; exit 2 ;;
  esac
done

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP_BUNDLE="${APP_BUNDLE:-$ROOT_DIR/dist/release/BarTender.app}"
INFO_PLIST="$APP_BUNDLE/Contents/Info.plist"
APP_BINARY="$APP_BUNDLE/Contents/MacOS/BarTender"
RESOURCE_BUNDLE="$APP_BUNDLE/Contents/Resources/BarTender_BarTender.bundle"

[[ -d "$APP_BUNDLE" && -f "$INFO_PLIST" && -x "$APP_BINARY" ]] || {
  printf 'Incomplete app bundle: %s\n' "$APP_BUNDLE" >&2
  exit 1
}

BUNDLE_ID="$(plutil -extract CFBundleIdentifier raw "$INFO_PLIST")"
VERSION="$(plutil -extract CFBundleShortVersionString raw "$INFO_PLIST")"
BUILD_NUMBER="$(plutil -extract CFBundleVersion raw "$INFO_PLIST")"
[[ "$BUNDLE_ID" == "io.github.aforno.bartender" ]] || { printf 'Unexpected bundle identifier: %s\n' "$BUNDLE_ID" >&2; exit 1; }
[[ "$VERSION" == "$(tr -d '[:space:]' < "$ROOT_DIR/VERSION")" ]] || { printf 'Version mismatch: %s\n' "$VERSION" >&2; exit 1; }
[[ "$BUILD_NUMBER" == "$(tr -d '[:space:]' < "$ROOT_DIR/BUILD_NUMBER")" ]] || { printf 'Build mismatch: %s\n' "$BUILD_NUMBER" >&2; exit 1; }
[[ -f "$APP_BUNDLE/Contents/Resources/Assets.car" ]] || { printf '%s\n' 'Compiled asset catalog is missing.' >&2; exit 1; }
[[ -f "$APP_BUNDLE/Contents/Resources/AppIcon.icns" ]] || { printf '%s\n' 'Compiled application icon is missing.' >&2; exit 1; }
[[ -d "$RESOURCE_BUNDLE" ]] || { printf '%s\n' 'SwiftPM resource bundle is missing from Contents/Resources.' >&2; exit 1; }
find "$RESOURCE_BUNDLE" -type f -name 'applet-manifest.schema.json' -print -quit | grep -q . || {
  printf '%s\n' 'Bundled manifest schema is missing.' >&2
  exit 1
}

for provider_icon in chatgpt claude grok; do
  find "$RESOURCE_BUNDLE" -type f -name "$provider_icon.png" -print -quit | grep -q . || {
    printf 'Provider icon is missing: %s.png\n' "$provider_icon" >&2
    exit 1
  }
done

for document in LICENSE CHANGELOG.md PRIVACY.md RELEASE_NOTES.md SECURITY.md SUPPORT.md THIRD_PARTY_NOTICES.md provider-icons.json; do
  [[ -f "$APP_BUNDLE/Contents/Resources/$document" ]] || {
    printf 'Release metadata is missing: %s\n' "$document" >&2
    exit 1
  }
done

/usr/bin/lipo "$APP_BINARY" -verify_arch arm64 x86_64 || {
  printf '%s\n' 'The release executable is not universal for arm64 and x86_64.' >&2
  exit 1
}

if strings "$APP_BINARY" | grep -q '/debug/'; then
  printf '%s\n' 'The packaged executable contains a debug build path.' >&2
  exit 1
fi

/usr/bin/codesign --verify --deep --strict --verbose=2 "$APP_BUNDLE"
SIGNING_DETAILS="$(/usr/bin/codesign -dvvv "$APP_BUNDLE" 2>&1)"
grep -q 'runtime' <<<"$SIGNING_DETAILS" || { printf '%s\n' 'Hardened runtime flag is missing.' >&2; exit 1; }
ENTITLEMENTS_PLIST="$(mktemp "${TMPDIR:-/tmp}/BarTender-Entitlements.XXXXXX")"
trap 'rm -f "$ENTITLEMENTS_PLIST"' EXIT
/usr/bin/codesign -d --entitlements :- "$APP_BUNDLE" > "$ENTITLEMENTS_PLIST" 2>/dev/null
[[ "$(/usr/libexec/PlistBuddy -c 'Print :com.apple.security.automation.apple-events' "$ENTITLEMENTS_PLIST" 2>/dev/null)" == "true" ]] || {
  printf '%s\n' 'The Apple Events entitlement is missing.' >&2
  exit 1
}
if /usr/libexec/PlistBuddy -c 'Print :com.apple.security.app-sandbox' "$ENTITLEMENTS_PLIST" >/dev/null 2>&1; then
  printf '%s\n' 'Unexpected App Sandbox entitlement conflicts with the documented trusted local tool model.' >&2
  exit 1
fi

if $DISTRIBUTION; then
  grep -q '^Authority=Developer ID Application:' <<<"$SIGNING_DETAILS" || { printf '%s\n' 'Developer ID Application signature is missing.' >&2; exit 1; }
  if grep -q '^TeamIdentifier=not set$' <<<"$SIGNING_DETAILS"; then
    printf '%s\n' 'A distribution Team ID is missing.' >&2
    exit 1
  fi
  /usr/sbin/spctl --assess --type execute --verbose=2 "$APP_BUNDLE"
  xcrun stapler validate "$APP_BUNDLE"
fi

if [[ -n "$DMG_PATH" ]]; then
  [[ -f "$DMG_PATH" ]] || { printf 'DMG not found: %s\n' "$DMG_PATH" >&2; exit 1; }
  /usr/bin/hdiutil verify "$DMG_PATH"
  if $DISTRIBUTION; then
    /usr/sbin/spctl --assess --type open --context context:primary-signature --verbose=2 "$DMG_PATH"
    xcrun stapler validate "$DMG_PATH"
  fi
fi

printf 'Verified Bar Tender %s (%s), bundle %s\n' "$VERSION" "$BUILD_NUMBER" "$BUNDLE_ID"
