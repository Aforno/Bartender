# Bar Tender 1.0.1

Bar Tender turns a plain-language request into a dedicated macOS menu bar tool using an already installed Codex, Claude, Grok, Gemini, or Antigravity (`agy`) CLI.

## Diagnostic focus (this build)

This prerelease is about whether menu bar items actually show up.

- Bundle identifier is `io.github.aforno.bartender.v2`, so Control Center starts from a clean host state.
- At most one individual applet status item by default, rendered as a compact square icon.
- Status items attach once from launch. The main window no longer forces an immediate re-registration.

## Distribution notice (read this)

This is a prerelease. It is not signed with an Apple Developer ID certificate and is not notarized by Apple.

Gatekeeper will block a normal double-click after download. That is expected.

### Install on macOS

1. Download the `BarTender-<version>.dmg` file listed in this release's assets.
2. Optionally verify the file against `SHA256SUMS.txt`.
3. Open the DMG and drag BarTender to Applications.
4. On first launch, use one of these:

   - In Finder, Control-click or right-click BarTender, then Open, then Open.
   - After a blocked launch: System Settings → Privacy & Security, scroll to the message about Bar Tender, then Open Anyway.
   - From Terminal, only if you trust this build:

     ```bash
     xattr -dr com.apple.quarantine /Applications/BarTender.app
     open /Applications/BarTender.app
     ```

5. Later launches can use a normal double-click.

A later release signed with Developer ID and notarized will drop this step, once Apple credentials exist.

### Requirements

- macOS 26 or newer
- Universal binary (Apple silicon and Intel)
- At least one local AI CLI signed in: `codex`, `claude`, `grok`, `gemini`, or `agy`

### What's in this release

- Review-before-run generated zsh tools. Approval is bound to the exact source and working directory.
- Opt-in setting to automatically approve provider-written edits to tools you already approved. New tools, imports, and automatic repairs still require review.
- Generated tools can read Mac component temperatures via `"$BARTENDER_CLI" --sensors` or `--sensors-json` (CPU, GPU, SoC, battery, ambient, memory, storage; °C; no elevated privileges).
- Provider and model selection with native ChatGPT, Claude, and Grok artwork.
- No generation deadline. Long provider runs continue until they finish or you cancel them.
- Launch at login, library export/import, contextual alerts, diagnostics export, provider setup, and update checks.
- A manager menu that stays usable with many running tools.
- Universal packaging for macOS 26 and newer. Not Developer ID signed. Gatekeeper bypass required once.

Approved generated code is not sandboxed. It runs with your user privileges and can reach local files, network services, commands, and credentials available to local processes. Read the source before you approve it.
