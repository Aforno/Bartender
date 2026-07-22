# Changelog

All notable user-visible changes are recorded here. Bar Tender follows semantic versioning.

## Unreleased

- Added an opt-in setting to automatically approve provider-written edits to previously approved generated tools. New tools, imports, and automatic repairs still require review.
- Added Mac component temperature readings for generated tools. Tools can run `"$BARTENDER_CLI" --sensors` (key=value lines) or `"$BARTENDER_CLI" --sensors-json` (per-sensor detail) to get CPU, GPU, SoC, battery, ambient, memory, and storage temperatures in °C — no extra software or elevated privileges needed, on Apple silicon and Intel.

## 1.0.0 — 2026-07-20

- Added generated menu bar tools through local Codex, Claude, and Grok CLIs, with provider and model selection.
- Added bounded validation retries and first-run diagnostic feedback so providers can repair generated tools instead of leaving them at “Needs Attention.”
- Fixed newly enabled tools showing stale placeholder data until their second scheduled refresh.
- Fixed in-app notification banners remaining visible indefinitely; they now dismiss automatically after five seconds.
- Added exact-source approval, automatic approval invalidation on edits, generated-tool environment minimization, and explicit local-code trust disclosures.
- Removed the AI generation timeout. Generation continues until the provider finishes or the user cancels it.
- Added provider brand icons throughout setup and model selection, plus a dedicated Bar Tender application icon.
- Added launch at login, contextual notification permission, library export/import, provider setup reopening, sanitized diagnostics export, support/privacy links, and user-initiated GitHub release checks.
- Added overflow handling for large tool libraries and clarified that closing the window leaves enabled menu bar tools running.
- Added universal Developer ID signing, hardened runtime, notarization, stapling, ZIP/DMG packaging, checksums, install smoke tests, and macOS 26 CI coverage on Apple silicon and Intel.
- Added end-to-end provider process tests for missing, unauthenticated, expired, malformed, cancelled, and successful generation states.
