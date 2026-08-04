# Releasing Bar Tender (ad-hoc)

This repository publishes **ad-hoc** universal binaries from `main`. No Apple Developer Program membership or repository secrets are required.

Gatekeeper will warn users on first launch. Keep the Control-click → Open flow documented in `RELEASE_NOTES.md`.

## How releases ship

Every push to `main` runs the `Release (ad-hoc)` workflow. It:

1. Validates that `VERSION` / `BUILD_NUMBER` are well-formed and that tag `v<VERSION>+build.<BUILD_NUMBER>` does not already exist
2. Packages a universal app with an ad-hoc signature
3. Verifies the bundle and smoke-tests the DMG, including bounded menu-bar diagnostics and status-item frame validation
4. Creates an **immutable** GitHub prerelease and tag `v<VERSION>+build.<BUILD_NUMBER>` for that commit; the tag is created by the release operation rather than pushed separately
5. Attaches ZIP, DMG, and `SHA256SUMS.txt`; a failed partial publication is cleaned up so the same build can be retried

Bump `VERSION` and/or `BUILD_NUMBER` before every new publish. Reusing a release identity or silently replacing assets is rejected.

## Checklist before merging to main

1. Update `VERSION` when the release identity should change (include an `-adhoc` or similar suffix so tags never collide with future signed releases). Increment `BUILD_NUMBER` for each new binary, and refresh `CHANGELOG.md` / `RELEASE_NOTES.md`.
2. Run `swift test` and `swift build -c release` locally if you want a pre-push check.
3. Optionally run the local universal packaging path:

   ```bash
   ./script/package_release.sh --adhoc --skip-notarization --arch universal
   ./script/verify_release.sh --app dist/release/BarTender.app --dmg "dist/release/BarTender-$(tr -d '[:space:]' < VERSION).dmg"
   ./script/install_smoke_test.sh "dist/release/BarTender-$(tr -d '[:space:]' < VERSION).dmg"
   ```

4. Merge or push to `main` and confirm CI plus the release workflow succeed.
5. Download the published DMG, verify the checksum, install it via the Gatekeeper bypass steps, and spot-check provider setup plus one generated tool.

## Local packaging (same as CI)

```bash
./script/package_release.sh --adhoc --skip-notarization --arch universal
./script/verify_release.sh \
  --app dist/release/BarTender.app \
  --dmg "dist/release/BarTender-$(tr -d '[:space:]' < VERSION).dmg"
```

## Returning to signed releases

Keep signed/notarized publishing on a dedicated path once Developer ID and App Store Connect credentials exist. Do not merge this workflow back over the Developer ID release path unless you intentionally retire notarization.
