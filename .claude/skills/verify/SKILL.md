---
name: verify
description: Build, launch, and drive the native Bar Tender macOS app for runtime verification.
---

# Verify Bar Tender

1. Build and launch the development bundle with `./script/build_and_run.sh --verify`.
2. Activate the app with `osascript -e 'tell application "Bar Tender" to activate'`.
3. Open Settings by clicking the `Settings…` item in the `Bar Tender` application menu through System Events.
4. Prefer the stable SwiftUI accessibility identifiers (`tool-prompt`, `submit-tool-prompt`, `auto-approve-generated-tool-edits`, `allow-and-run.<UUID>`) when driving controls. A small temporary Swift script using `AXUIElementCreateApplication`, `kAXIdentifierAttribute`, `kAXValueAttribute`, and `kAXPressAction` can set text and press controls reliably.
5. Capture evidence with `screencapture -x /tmp/<name>.png`, then inspect the image.

For approval-flow changes, use a harmless generated tool, observe both `Live` and `Review required` states, restore its approval afterward, and return any changed preference to its original value.
