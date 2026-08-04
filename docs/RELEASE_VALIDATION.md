# Release Validation Record

Validation baseline: 2026-07-20
Automated-gate refresh: 2026-08-04
Host: macOS 26.5.1, Apple silicon, Xcode 26 toolchain

## Automated gates

- `swift test`: the suite covers provider subprocesses, malformed output, bounded cancellation, revoked authentication downgrade, exact-source approval lifecycle, archive migration and duplicate-ID rejection, runtime-state isolation, process-tree cleanup, multi-tool relaunch, overflow planning, long logs/titles, model cache/config drift, update-channel selection, timer edge cases, launch mode, provider icon caching, and menu-bar diagnostics.
- `swift build -c release`: runs in CI for both Apple silicon and Intel.
- `script/package_release.sh --adhoc --skip-notarization --arch universal`: produces a sealed hardened-runtime app, ZIP, DMG, and SHA-256 list from release binaries.
- `script/verify_release.sh`: confirms stable bundle identity/version, compiled icon catalog, provider assets, resource schema, strict code seal, runtime flag, and DMG checksum.
- `script/install_smoke_test.sh`: mounts the DMG read-only, copies the app to a clean temporary Applications directory, launches the packaged binary with `--menu-bar-diagnostics` and an isolated smoke library, and fails within a bounded timeout if bootstrap, manager/applet status items, titles, or paintable menu-bar frames do not initialise.
- The packaged executable is a universal Mach-O containing arm64 and x86_64 slices.

Distribution verification is enforced in the release workflow on every push to `main`. A local Developer ID/Gatekeeper/notarization pass requires the maintainer's certificate and App Store Connect notarization credentials; the repository does not contain those secrets.

## Live provider compatibility

Installed versions checked:

- Codex CLI 0.144.5: version/auth probes pass and a real schema-constrained generation succeeds with the release invocation flags.
- Claude Code 2.1.214: local `auth status` reports signed in, but a real request returns a revoked OAuth 401. Bar Tender now maps this live response to an expired-auth setup state and asks the user to sign in again.
- Grok 0.2.106: the documented non-generative `grok models` check reports an expired/rejected refresh token. Bar Tender correctly keeps Grok unavailable and directs the user to `grok login`.

No credential material, provider response body, prompt history, or generated source is included in diagnostics or this record.

## Runtime UI and accessibility inspection

The assembled `.app` was launched and inspected through the macOS accessibility tree and screenshots:

- First-run/empty library is understandable and contains the generated-code trust disclosure before approval.
- Provider artwork renders at the intended size in Settings and the model picker; an initial oversized AppKit `Menu` image regression was found and fixed by bounding the underlying `NSImage` logical size.
- At the 720×500 minimum, empty-state content scrolls above the fixed composer without overlap; an initial safe-area overlap was found and fixed by giving detail and composer separate layout regions.
- The sidebar Settings row opens the native Settings scene; the nonfunctional selector fallback was replaced with `SettingsLink`.
- Critical controls expose accessibility labels, values, and stable identifiers, including search, prompt, model/provider options, submit/cancel, enable/approval, launch-at-login, update, diagnostics, and manager-tool rows.
- Keyboard routes include `⌘N`, `⌘K`, `⌘↩`, `⌘,`, Escape cancellation/search clearing, and standard macOS window navigation.
- Reduced-motion checks guard custom hover/banner/control animations; native semantic colors and system materials preserve light/dark contrast. Long values are line-limited or scrollable, menu titles are capped, and provider logs retain the latest 2,000 events.
- Notification permission is not requested at bootstrap or by sample creation; it is requested when the user explicitly enables notifications or an alert toggle.

## CI matrix

The committed CI matrix targets macOS 26 on both Apple silicon and Intel, and runs on pushes to `main` and `develop` plus pull requests. The release workflow on `main` only packages the ad-hoc universal app, verifies the sealed layout, smoke-tests the DMG, and publishes an immutable `v<VERSION>+build.<BUILD_NUMBER>` prerelease. Partial release failures are cleaned up so the same build can be retried; existing completed release identities are never replaced.
