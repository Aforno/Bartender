# Releasing Bar Tender

This repository publishes universal prerelease binaries from `main`. The current path does not need an Apple Developer Program membership or repository secrets.

Packaged binaries are not Developer ID signed or notarized. Gatekeeper will warn users on first launch. Keep the Control-click → Open flow documented in `RELEASE_NOTES.md`.

## How releases ship

Every push to `main` runs the `Release` workflow. It:

1. Validates that `VERSION` / `BUILD_NUMBER` are well-formed and that tag `v<VERSION>+build.<BUILD_NUMBER>` does not already exist
2. Packages a universal app with an ad-hoc code signature. That is a technical signing mode, not part of the product version.
3. Writes `BarTenderUpdateChannel=prerelease` into the app's Info.plist so in-app update checks track GitHub prereleases
4. Verifies the bundle and smoke-tests the DMG, including bounded menu-bar diagnostics and status-item frame validation
5. Creates an immutable GitHub prerelease and tag `v<VERSION>+build.<BUILD_NUMBER>` for that commit. The tag is created by the release operation rather than pushed separately.
6. Attaches ZIP, DMG, and `SHA256SUMS.txt`. A failed partial publication is cleaned up so the same build can be retried.

Bump `VERSION` and/or `BUILD_NUMBER` before every new publish. Reusing a release identity or silently replacing assets is rejected.

### Version and tag identity

| Field | Example | Source |
| --- | --- | --- |
| Marketing version | `1.0.1` | `VERSION` → `CFBundleShortVersionString` |
| Build number | `2` | `BUILD_NUMBER` → `CFBundleVersion` |
| Release tag | `v1.0.1+build.2` | `v${VERSION}+build.${BUILD_NUMBER}` |
| Update channel | `prerelease` or `stable` | `BarTenderUpdateChannel` in Info.plist |
| GitHub release title | `Bar Tender 1.0.1 (build 2)` | workflow |

Do not encode the signing mode or update channel into the semantic version string.

## Checklist before merging to main

1. Update `VERSION` when the release identity should change. Increment `BUILD_NUMBER` for each new binary, and refresh `CHANGELOG.md` / `RELEASE_NOTES.md`.
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

The `--adhoc` flag only selects an ad-hoc codesign identity for CI and local builds. It does not change the product version.

## Returning to signed stable releases

Keep signed and notarized publishing on a dedicated path once Developer ID and App Store Connect credentials exist. Those builds should set `BarTenderUpdateChannel=stable`, which packaging does automatically without `--adhoc`, and publish non-prerelease GitHub releases so stable installs only see stable updates.
