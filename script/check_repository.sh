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

# Immutable release identity: if tag v$VERSION already exists for a different
# commit, publishing would require force-moving the tag (disallowed).
tag="v${version}"
if git rev-parse -q --verify "refs/tags/${tag}" >/dev/null 2>&1; then
  tag_sha="$(git rev-list -n 1 "refs/tags/${tag}" 2>/dev/null || true)"
  head_sha="$(git rev-parse HEAD 2>/dev/null || true)"
  if [[ -n "$tag_sha" && -n "$head_sha" && "$tag_sha" != "$head_sha" ]]; then
    # Warn in local hygiene; release workflow fails hard. Allow develop work.
    if [[ "${BARTENDER_ENFORCE_RELEASE_TAG:-}" == "1" ]]; then
      fail "release tag ${tag} already exists for ${tag_sha}; bump VERSION/BUILD_NUMBER before publishing (HEAD is ${head_sha})"
    fi
  fi
fi

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
if set(manifest) != {"chatgpt", "claude", "grok", "gemini", "agy"}:
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
