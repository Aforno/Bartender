#!/usr/bin/env bash
set -euo pipefail

DMG_PATH="${1:-}"
[[ -f "$DMG_PATH" ]] || { printf 'DMG not found: %s\n' "$DMG_PATH" >&2; exit 1; }
if pgrep -x BarTender >/dev/null 2>&1; then
  printf '%s\n' 'Refusing install smoke while another BarTender process is running.' >&2
  exit 1
fi

SMOKE_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/BarTender-InstallSmoke.XXXXXX")"
ATTACH_PLIST="$SMOKE_ROOT/attach.plist"
MOUNT_POINT=""
APP_PID=""

cleanup() {
  if [[ -n "$APP_PID" ]]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
  fi
  if [[ -n "$MOUNT_POINT" ]]; then
    hdiutil detach "$MOUNT_POINT" -quiet >/dev/null 2>&1 || true
  fi
  rm -rf "$SMOKE_ROOT"
}
trap cleanup EXIT

hdiutil attach "$DMG_PATH" -readonly -nobrowse -plist > "$ATTACH_PLIST"
MOUNT_POINT="$(plutil -p "$ATTACH_PLIST" \
  | sed -n 's/.*"mount-point" => "\(.*\)"/\1/p' \
  | head -1)"
[[ -n "$MOUNT_POINT" ]] || { printf '%s\n' 'Could not resolve the mounted DMG volume.' >&2; exit 1; }
[[ -d "$MOUNT_POINT/BarTender.app" ]] || { printf '%s\n' 'Mounted DMG does not contain BarTender.app.' >&2; exit 1; }
[[ -L "$MOUNT_POINT/Applications" ]] || { printf '%s\n' 'Mounted DMG is missing the Applications shortcut.' >&2; exit 1; }

INSTALL_ROOT="$SMOKE_ROOT/Applications"
mkdir -p "$INSTALL_ROOT"
/usr/bin/ditto "$MOUNT_POINT/BarTender.app" "$INSTALL_ROOT/BarTender.app"
/usr/bin/open -n "$INSTALL_ROOT/BarTender.app"

for _ in {1..20}; do
  APP_PID="$(pgrep -x BarTender | head -1 || true)"
  [[ -n "$APP_PID" ]] && break
  sleep 0.25
done
[[ -n "$APP_PID" ]] || { printf '%s\n' 'BarTender did not stay running after a clean copy and launch.' >&2; exit 1; }
kill -0 "$APP_PID"
printf 'Clean install smoke passed from %s (pid %s).\n' "$DMG_PATH" "$APP_PID"
