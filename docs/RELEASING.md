# Releasing Bar Tender

The release workflow builds the same app layout used by local packaging. Distribution mode refuses ad-hoc identities and refuses to skip notarization.

## One-time repository configuration

Configure these GitHub Actions secrets:

- `DEVELOPER_ID_CERTIFICATE_BASE64`: base64-encoded Developer ID Application `.p12`.
- `DEVELOPER_ID_CERTIFICATE_PASSWORD`: export password for that `.p12`.
- `DEVELOPER_ID_APPLICATION`: full identity, beginning with `Developer ID Application:`.
- `RELEASE_KEYCHAIN_PASSWORD`: strong ephemeral CI keychain password.
- `APP_STORE_CONNECT_API_KEY_BASE64`: base64-encoded notarization API `.p8`.
- `APP_STORE_CONNECT_KEY_ID`: App Store Connect API key ID.
- `APP_STORE_CONNECT_ISSUER_ID`: App Store Connect issuer ID.

Keep the certificate and API key outside the repository. Rotate them through Apple and repository secrets if access changes.

## Release checklist

1. Update `VERSION`, increment `BUILD_NUMBER`, `CHANGELOG.md`, and `RELEASE_NOTES.md`.
2. Run `swift test` and `swift build -c release`.
3. Run the local universal packaging and install smoke path with `--adhoc --skip-notarization`.
4. Confirm CI passes macOS 26 on both Apple silicon and Intel.
5. Create and push an annotated `v<contents-of-VERSION>` tag.
6. The `Release` workflow imports an ephemeral signing identity, builds universal, applies hardened runtime and entitlements, notarizes and staples the app and DMG, enforces Gatekeeper assessment, mounts/copies/launches the DMG, emits checksums, and publishes the assets.
7. Download the published DMG on a clean Mac, verify its checksum, install it, check all provider setup states, create and approve a generated tool, revise it, and confirm the revision requires approval again.

## Local distribution invocation

With a Developer ID identity installed and notarization credentials available:

```bash
export BARTENDER_SIGNING_IDENTITY='Developer ID Application: Example (TEAMID)'
export BARTENDER_NOTARY_KEY_PATH='/secure/path/AuthKey.p8'
export BARTENDER_NOTARY_KEY_ID='KEYID'
export BARTENDER_NOTARY_ISSUER_ID='ISSUER-UUID'
./script/package_release.sh --arch universal
./script/verify_release.sh --distribution \
  --app dist/release/BarTender.app \
  --dmg "dist/release/BarTender-$(tr -d '[:space:]' < VERSION).dmg"
```

The supported alternative is a preconfigured `notarytool` keychain profile through `BARTENDER_NOTARY_PROFILE`.
