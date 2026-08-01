# Releasing Bar Tender (ad-hoc)

This repository publishes **ad-hoc** universal binaries from `main`. No Apple Developer Program membership or repository secrets are required.

Gatekeeper will warn users on first launch. Keep the Control-click → Open flow documented in `RELEASE_NOTES.md`.

## How releases ship

Every push to `main` runs the `Release (ad-hoc)` workflow. It:

1. Packages a universal app with an ad-hoc signature
2. Verifies the bundle and smoke-tests the DMG
3. Force-updates the `v<contents-of-VERSION>` tag to that commit
4. Creates or updates the matching **prerelease** with ZIP, DMG, and `SHA256SUMS.txt`

Bumping `VERSION` (and usually `BUILD_NUMBER`) starts a new tag/release; leaving them unchanged refreshes assets on the existing prerelease.

## Checklist before merging to main

1. Update `VERSION` when the release identity should change (include an `-adhoc` or similar suffix so tags never collide with future signed releases). Increment `BUILD_NUMBER` if needed, and refresh `CHANGELOG.md` / `RELEASE_NOTES.md`.
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
