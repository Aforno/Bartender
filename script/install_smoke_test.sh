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
DIAG_JSON="$SMOKE_ROOT/diagnostics.json"
SMOKE_LIBRARY="$SMOKE_ROOT/library"
MOUNT_POINT=""
APP_PID=""

cleanup() {
  if [[ -n "${APP_PID:-}" ]]; then
    kill "$APP_PID" >/dev/null 2>&1 || true
    wait "$APP_PID" >/dev/null 2>&1 || true
  fi
  # Diagnostics mode exits itself; sweep any leftover process from the bundle.
  pkill -x BarTender >/dev/null 2>&1 || true
  if [[ -n "${MOUNT_POINT:-}" ]]; then
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
mkdir -p "$INSTALL_ROOT" "$SMOKE_LIBRARY"
/usr/bin/ditto "$MOUNT_POINT/BarTender.app" "$INSTALL_ROOT/BarTender.app"

APP_BIN="$INSTALL_ROOT/BarTender.app/Contents/MacOS/BarTender"
[[ -x "$APP_BIN" ]] || { printf '%s\n' 'Packaged executable is missing or not executable.' >&2; exit 1; }

# Launch the packaged binary in diagnostics mode with an isolated library so the
# smoke test never touches the developer's Application Support directory.
# --silent-launch avoids stealing focus during CI.
set +e
"$APP_BIN" \
  --menu-bar-diagnostics \
  --smoke-library "$SMOKE_LIBRARY" \
  --silent-launch \
  >"$DIAG_JSON" 2>"$SMOKE_ROOT/diagnostics.err"
DIAG_STATUS=$?
set -e

if [[ ! -s "$DIAG_JSON" ]]; then
  printf '%s\n' 'Menu-bar diagnostics produced no JSON output.' >&2
  if [[ -s "$SMOKE_ROOT/diagnostics.err" ]]; then
    cat "$SMOKE_ROOT/diagnostics.err" >&2
  fi
  exit 1
fi

# Parse required fields with Python (always available on macOS runners).
python3 - "$DIAG_JSON" "$DIAG_STATUS" <<'PY'
import json
import sys

path, status = sys.argv[1], int(sys.argv[2])
with open(path, encoding="utf-8") as handle:
    raw = handle.read().strip().splitlines()[-1]
try:
    data = json.loads(raw)
except json.JSONDecodeError as exc:
    raise SystemExit(f"Menu-bar diagnostics JSON is invalid: {exc}: {raw!r}") from exc

failures = []
if not data.get("bootstrapCompleted"):
    failures.append("bootstrap never finished")
if not data.get("managerStatusItemInstalled"):
    failures.append("manager status item is not installed")
if data.get("managerItemCount") != 1:
    failures.append(f"expected managerItemCount=1, got {data.get('managerItemCount')}")
if not data.get("appletStatusItemManagerAttached"):
    failures.append("per-applet status item manager is not attached")
if int(data.get("enabledAppletCount") or 0) < 1:
    failures.append("expected at least one enabled applet")
if int(data.get("managedAppletItemCount") or 0) < 1:
    failures.append("enabled applet present but no managed status item")
for item in data.get("appletItems") or []:
    if not item.get("titleNonEmpty"):
        failures.append(f"applet item title unexpectedly empty for {item.get('name')}")

if failures:
    print("Menu-bar diagnostics failed:", "; ".join(failures), file=sys.stderr)
    print(raw, file=sys.stderr)
    raise SystemExit(1)

if status != 0:
    print(f"Diagnostics process exited with status {status} but JSON looked healthy.", file=sys.stderr)
    raise SystemExit(status)

print(
    "Clean install smoke passed from diagnostics "
    f"(manager={data.get('managerItemCount')}, "
    f"managedApplets={data.get('managedAppletItemCount')}, "
    f"enabled={data.get('enabledAppletCount')})."
)
PY

printf 'Clean install smoke passed from %s.\n' "$DMG_PATH"
