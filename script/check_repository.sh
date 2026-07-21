#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

fail() {
  printf 'Repository check failed: %s\n' "$1" >&2
  exit 1
}

git diff --check
swift package dump-package >/dev/null

for script in script/*.sh; do
  bash -n "$script"
  [[ -x "$script" ]] || fail "$script is not executable"
done

for plist in Packaging/Info.plist Packaging/BarTender.entitlements; do
  /usr/bin/plutil -lint "$plist" >/dev/null
done

version="$(tr -d '[:space:]' < VERSION)"
build_number="$(tr -d '[:space:]' < BUILD_NUMBER)"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.-][A-Za-z0-9.-]+)?$ ]] || fail "VERSION is not semantic"
[[ "$build_number" =~ ^[1-9][0-9]*$ ]] || fail "BUILD_NUMBER is not a positive integer"

if git ls-files | grep -Eq '^(\.build|\.build-release|dist)/'; then
  fail "generated build output is tracked"
fi

if git grep -I -n -E '/Users/[[:alnum:]_.-]+/' -- . ':!script/check_repository.sh'; then
  fail "a machine-specific home path is tracked"
fi

python3 - <<'PY'
import hashlib
import json
from pathlib import Path

manifest = json.loads(Path("Packaging/provider-icons.json").read_text())
if set(manifest) != {"chatgpt", "claude", "grok"}:
    raise SystemExit("Repository check failed: provider icon manifest has unexpected entries")

for provider, entry in manifest.items():
    icon_path = Path(entry["file"])
    if not icon_path.is_file():
        raise SystemExit(f"Repository check failed: provider icon is missing: {icon_path}")
    actual_hash = hashlib.sha256(icon_path.read_bytes()).hexdigest()
    if actual_hash != entry["sha256"]:
        raise SystemExit(f"Repository check failed: provider icon checksum changed: {icon_path}")
PY

printf '%s\n' 'Repository hygiene checks passed.'
