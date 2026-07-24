# Releasing Bar Tender (ad-hoc branch)

This branch publishes **ad-hoc** universal binaries. No Apple Developer Program membership or repository secrets are required.

Gatekeeper will warn users on first launch. Document the Control-click → Open flow in `RELEASE_NOTES.md` for every tag.

## Release checklist

1. Update `VERSION` (include an `-adhoc` or similar suffix so tags never collide with future signed releases on `main`), increment `BUILD_NUMBER` if needed, and refresh `CHANGELOG.md` / `RELEASE_NOTES.md`.
2. Run `swift test` and `swift build -c release`.
3. Run the local universal packaging path:

   ```bash
   ./script/package_release.sh --adhoc --skip-notarization --arch universal
   ./script/verify_release.sh --app dist/release/BarTender.app --dmg "dist/release/BarTender-$(tr -d '[:space:]' < VERSION).dmg"
   ./script/install_smoke_test.sh "dist/release/BarTender-$(tr -d '[:space:]' < VERSION).dmg"
   ```

4. Confirm CI passes on `main`/this branch as usual.
5. Create and push an annotated `v<contents-of-VERSION>` tag from **this branch**.
6. The `Release (ad-hoc)` workflow packages the universal app with an ad-hoc signature, verifies the bundle, smoke-tests the DMG, and publishes a **prerelease** with ZIP, DMG, and `SHA256SUMS.txt`.
7. Download the published DMG, verify the checksum, install it via the Gatekeeper bypass steps, and spot-check provider setup plus one generated tool.

## Local packaging (same as CI)

```bash
./script/package_release.sh --adhoc --skip-notarization --arch universal
./script/verify_release.sh \
  --app dist/release/BarTender.app \
  --dmg "dist/release/BarTender-$(tr -d '[:space:]' < VERSION).dmg"
```

## Returning to signed releases

Keep signed/notarized publishing on `main` once Developer ID and App Store Connect credentials exist. Do not merge this workflow back over the Developer ID release path unless you intentionally retire notarization.
