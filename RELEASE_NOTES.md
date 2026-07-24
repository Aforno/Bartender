# Bar Tender 1.0.0-adhoc

Bar Tender turns a plain-language request into a dedicated macOS menu bar tool using an already installed Codex, Claude, or Grok CLI.

## Distribution notice (read this)

This is an **ad-hoc (unsigned) prerelease**. It is **not** signed with an Apple Developer ID certificate and is **not** notarized by Apple.

Gatekeeper will block a normal double-click after download. That is expected.

### Install on macOS

1. Download the `BarTender-<version>.dmg` file listed in this release's assets.
2. Optionally verify the file against `SHA256SUMS.txt`.
3. Open the DMG and drag **BarTender** to **Applications**.
4. First launch — use one of these:

   - **Finder:** Control-click (or right-click) **BarTender** → **Open** → **Open**.
   - **Or** after a blocked launch: **System Settings → Privacy & Security** → scroll to the message about Bar Tender → **Open Anyway**.
   - **Or** from Terminal (only if you trust this build):

     ```bash
     xattr -dr com.apple.quarantine /Applications/BarTender.app
     open /Applications/BarTender.app
     ```

5. Later launches can use a normal double-click.

A future release signed with Developer ID and notarized will remove this step when Apple credentials are available.

### Requirements

- macOS 26 or newer
- Universal binary (Apple silicon and Intel)
- At least one local AI CLI signed in: `codex`, `claude`, or `grok`

### What's in this release

- Review-before-run generated zsh tools with approval bound to the exact source and working directory.
- Opt-in setting to automatically approve provider-written edits to tools you already approved (new tools, imports, and automatic repairs still require review).
- Generated tools can read Mac component temperatures via `"$BARTENDER_CLI" --sensors` or `--sensors-json` (CPU, GPU, SoC, battery, ambient, memory, storage; °C; no elevated privileges).
- Provider and model selection with native ChatGPT, Claude, and Grok artwork.
- No generation deadline: long provider runs continue until completion or explicit cancellation.
- Launch at login, library export/import, contextual alerts, diagnostics export, provider setup, and update checks.
- A manager menu that remains usable with many running tools.
- Universal ad-hoc packaging for macOS 26 and newer (unsigned; Gatekeeper bypass required once).

Important trust note: approved generated code is not sandboxed. It runs with your user privileges and can access local files, network services, commands, and credentials available to local processes. Review source before approval.
