# Bar Tender

[![CI](https://github.com/Aforno/Bartender/actions/workflows/ci.yml/badge.svg)](https://github.com/Aforno/Bartender/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

You describe a utility in English. Bar Tender asks a CLI already on your Mac to write a zsh tool for it, then hangs that tool in the menu bar. It does not run until you approve the exact source.

The CLIs it knows are Codex, Claude, Grok, Gemini, and Antigravity (`agy`). You have to have them installed and signed in. The app never asks for API keys.

`main` publishes a universal prerelease ZIP and DMG on every push (`v<version>+build.<n>`). Those builds are hardened-runtime sealed. They are not Developer ID signed and not notarized. Gatekeeper will block a normal double-click the first time. That is expected. The release notes cover the Control-click Open flow. A signed stable channel can exist later, once Developer ID credentials exist.

## What it does

Describe a utility:

- "Watch localhost port 3000 and notify me when it goes offline."
- "Show CPU and memory usage."
- "Show CPU, GPU, and battery temperatures."
- "Create a 25-minute focus timer."
- "Show the current Git branch and number of changed files."

Select an existing tool in the library and the composer becomes an editor. The next message includes that tool's current manifest and source, then replaces it in place under the same menu bar item. Open New Tool, or press `⌘N`, to drop the editing context and start a separate tool.

The provider returns a generated-tool manifest with the complete source for a one-shot executable. Validator failures are retried with concrete feedback. Bar Tender installs the result under Application Support, creates the status item immediately, and waits for you to review and approve the source. After approval, an unhealthy or failed first run is sent back to the same provider for an in-place repair.

Changed source needs review again. Settings has an opt-in toggle that auto-approves later provider-written edits to tools you already approved. New tools, imports, and automatic repairs still stop for review.

Generated tools return structured menu output: `title`, `status`, `details`, `healthy`, and template `values`.

Older saved samples still use these built-in kinds:

| Kind | Behavior |
| --- | --- |
| `timer` / `countdown` | Countdown with start/pause/reset and optional completion notifications |
| `httpMonitor` | Polls an HTTP(S) URL |
| `portMonitor` | TCP probe of host:port |
| `systemMetrics` | CPU and/or memory usage |
| `gitStatus` | Branch name + changed file count |
| `shellCommand` | Runs only after explicit user approval in the inspector. Approval is bound to the exact command and working directory. The base tool's availability on this Mac is verified at creation time |

New natural-language requests use `generatedTool`. Approval is bound to the exact generated source and working directory, so an edit invalidates the prior fingerprint. Auto-approve only records a new fingerprint for provider-written revisions of tools you already approved.

## Requirements

- macOS 26+
- Swift 5.9+ / Xcode command-line tools
- At least one local AI CLI on your shell `PATH`, signed in:

| Provider | CLI | Auth |
| --- | --- | --- |
| Codex | `codex` | `codex login` |
| Claude | `claude` | `claude auth login` |
| Grok | `grok` | `grok login` |
| Gemini | `gemini` | Sign in via `gemini` |
| Antigravity | `agy` | Sign in via `agy` |

Bar Tender never asks for API keys. Pick a provider in the toolbar, composer, menu bar panel, or Settings.

## Run

```bash
chmod +x script/build_and_run.sh
./script/build_and_run.sh
```

Optional:

```bash
./script/build_and_run.sh --verify
./script/build_and_run.sh --logs
./script/build_and_run.sh --telemetry
```

The script creates a development app bundle at `dist/BarTender.app`. That is not a signed release.

## Install a release

Prerelease DMGs land on [GitHub Releases](https://github.com/Aforno/Bartender/releases) from every push to `main`. Download the DMG, check it against `SHA256SUMS.txt`, open it, and drag BarTender to Applications.

On first launch, Control-click the app, choose Open, then Open again. Privacy & Security → Open Anyway also works. Current prereleases are not notarized, so a normal double-click fails until you approve the app once. Builds are universal for Apple silicon and Intel and need macOS 26 or newer.

Bar Tender checks for updates only when you choose Check for Updates in Settings. If a newer GitHub release exists, it opens that page. It never replaces the app silently.

## Test

```bash
./script/check_repository.sh
swift test
swift build -c release
```

To exercise the complete local packaging path with ad-hoc codesign, for CI and local use:

```bash
./script/package_release.sh --adhoc --skip-notarization --arch universal
./script/verify_release.sh --app dist/release/BarTender.app --dmg dist/release/BarTender-1.0.1.dmg
./script/install_smoke_test.sh dist/release/BarTender-1.0.1.dmg
```

Prereleases are how the app ships today. Developer ID signing and notarization wait on a future stable channel. See [docs/RELEASING.md](docs/RELEASING.md).

## Provider integration (CLI-only)

Bar Tender finds each CLI from your login shell environment and probes version plus auth.

### Codex
Documented `codex exec` flags only: `--json`, `--sandbox read-only`, `--output-schema`, `--output-last-message`, `--ephemeral`, …

### Claude
Documented print mode: `claude -p --output-format json --json-schema … --tools "" --permission-mode dontAsk --no-session-persistence`

### Grok
Documented single-turn mode: `grok --single … --json-schema … --output-format json --permission-mode dontAsk --tools "" --max-turns 2`

### Gemini
Documented headless mode: `gemini --prompt … --output-format json --approval-mode plan --skip-trust`

### Antigravity (`agy`)
Documented print mode: `agy --print … --mode plan --sandbox`

All runs go through `Process` with stdout/stderr capture and cancellation. Generation has no time limit. It continues until the provider finishes or you cancel. Auth is never requested as an API key inside the app.

Saved applets are normalized and validated again before startup. Invalid entries are skipped and copied to a recovery sidecar. They are not executed, and they do not wipe the rest of the library.

## App UI

- Natural-language tool generation field
- Provider execution progress and logs
- Live menu bar preview
- Inspector for settings, including shell approval
- Library of saved applets
- One live AppKit status item per enabled tool, created as soon as generation succeeds, plus an AppKit wine-glass manager status item. Left-click opens the composer. Right-click opens the menu.
- Launch at login, library export/import, provider setup, sanitized diagnostics export, and user-initiated update checks in Settings
- Closing the window leaves enabled menu bar tools running. Quit and Stop Tools ends them.

## Project layout

```
Sources/BarTender/
  App/           # @main + AppDelegate
  Models/        # Manifests, provider status, runtime snapshots
  Stores/        # Validated persistence + app model
  Services/      # Provider CLIs, approvals, probes, runtime engine
  Views/         # SwiftUI workspace + menu bar
  Support/       # Logging, title rendering
  Resources/     # Shared JSON Schema for provider structured output
script/build_and_run.sh
script/package_release.sh
Packaging/      # Info.plist, entitlements, and app icon asset catalog
.codex/environments/environment.toml
```

Early interface explorations live in [docs/design-concepts.html](docs/design-concepts.html) as design history, not the current product spec.

## Security

Generated tools are local zsh executables. New and imported tools stay inert until you review and approve their exact source and working directory. An opt-in setting can automatically approve later provider-written revisions to tools you already approved. Automatic repairs still stop for review.

Approved code runs with Bar Tender's local process permissions. There is no security sandbox around it. That is the point of the review step, and also the risk. See [SECURITY.md](SECURITY.md) for the trust model and private vulnerability reporting.

[PRIVACY.md](PRIVACY.md) covers local data and network behavior. [SUPPORT.md](SUPPORT.md) has support routes. [CHANGELOG.md](CHANGELOG.md) has version history. [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) has provider icon attribution and trademark notices.

## Contributing

Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md) before opening a pull request.

## License

[MIT License](LICENSE).
