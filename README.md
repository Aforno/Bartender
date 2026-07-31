# Bar Tender

[![CI](https://github.com/Aforno/Bartender/actions/workflows/ci.yml/badge.svg)](https://github.com/Aforno/Bartender/actions/workflows/ci.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

A native macOS app that turns natural-language descriptions into live menu bar applets.

> **Project status:** This branch ships **ad-hoc (unsigned) binaries** so testers can download a DMG without a paid Apple Developer Program membership. Builds are universal, hardened-runtime sealed, and published as ZIP/DMG prereleases. They are **not** Developer ID signed or notarized—users must bypass Gatekeeper on first open (see the release notes). The `main` branch still targets the paid-account signed/notarized path.

Bar Tender uses an already installed and authenticated **Codex, Claude, Grok, Gemini, or Antigravity (`agy`) CLI** on your Mac. It does **not** ask for API keys. Each prompt produces a dedicated, reviewable zsh tool artifact that becomes its own live menu bar item.

## What it does

Describe a utility:

- “Watch localhost port 3000 and notify me when it goes offline.”
- “Show CPU and memory usage.”
- “Show CPU, GPU, and battery temperatures.”
- “Create a 25-minute focus timer.”
- “Show the current Git branch and number of changed files.”

Select an existing tool in the library and the same composer becomes an editor: your next message is sent with that tool's current manifest and source, then replaces it in place under the same menu bar item. Open **New Tool** (or press `⌘N`) to clear the editing context and build a separate tool.

The selected provider returns a **validated generated-tool manifest** containing the complete source for a one-shot executable. Bar Tender retries validator failures with concrete feedback, installs the result under Application Support, creates its status item immediately, and waits for explicit source review/approval before its first execution. After approval, an unhealthy or failed first run is sent back to the selected provider for an in-place repair. By default, changed source requires review again; an opt-in Settings toggle can automatically approve provider-written edits to tools you previously approved. Generated tools return structured live menu output (`title`, `status`, `details`, `healthy`, and template `values`).

The library also understands these built-in applet kinds for saved samples and backwards compatibility:

| Kind | Behavior |
| --- | --- |
| `timer` / `countdown` | Countdown with start/pause/reset and optional completion notifications |
| `httpMonitor` | Polls an HTTP(S) URL |
| `portMonitor` | TCP probe of host:port |
| `systemMetrics` | CPU and/or memory usage |
| `gitStatus` | Branch name + changed file count |
| `shellCommand` | Runs only after **explicit user approval** in the inspector; approval is bound to the exact command and working directory. The base tool's availability on this Mac is verified at creation time |

New natural-language requests use `generatedTool` instead of selecting one of these pre-made implementations. Approval is bound to the exact generated source and working directory, so an edit invalidates the prior fingerprint. The optional auto-approve setting records a new fingerprint only for provider-written revisions to tools you already approved.

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

The script creates a development app bundle at `dist/BarTender.app`. It is not a signed release artifact.

## Install a release

Ad-hoc prerelease DMGs are published on [GitHub Releases](https://github.com/Aforno/Bartender/releases). Download the DMG, verify it against `SHA256SUMS.txt`, open it, and drag **BarTender** to **Applications**.

**First launch:** Control-click the app → **Open** → **Open** (or use **Privacy & Security → Open Anyway**). Ad-hoc builds are not notarized, so Gatekeeper blocks a normal double-click until you approve the app once. Artifacts are universal for Apple silicon and Intel and require macOS 26 or newer.

Bar Tender checks for updates only when you choose **Check for Updates** in Settings. When a newer GitHub release exists, it opens that release for a user-controlled download and install; it never replaces the app silently.

## Test

```bash
./script/check_repository.sh
swift test
swift build -c release
```

To exercise the complete local packaging path with an ad-hoc signature:

```bash
./script/package_release.sh --adhoc --skip-notarization --arch universal
./script/verify_release.sh --app dist/release/BarTender.app --dmg dist/release/BarTender-1.0.0.dmg
./script/install_smoke_test.sh dist/release/BarTender-1.0.0.dmg
```

Developer ID signing and notarization are intentionally mandatory for distribution builds. See [docs/RELEASING.md](docs/RELEASING.md).

## Provider integration (CLI-only)

Bar Tender discovers each CLI from your login shell environment and probes version + auth.

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

All runs go through `Process` with stdout/stderr capture and cancellation. Generation has no time limit and continues until the provider finishes or the user cancels it. Auth is never requested as an API key inside the app.

Saved applets are normalized and validated again before startup. Invalid entries are skipped and copied to a recovery sidecar instead of being executed or causing the valid library to disappear.

## App UI

- Natural-language tool generation field
- Provider execution progress + logs
- Live menu bar preview
- Inspector for settings (including shell approval)
- Library of saved applets
- One live AppKit status item per enabled tool, created as soon as generation succeeds, plus a SwiftUI manager `MenuBarExtra`
- Launch at login, library export/import, provider setup, sanitized diagnostics export, and user-initiated update checks in Settings
- Explicit close-versus-quit wording: closing the window leaves enabled menu bar tools running; **Quit and Stop Tools** ends them

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

Early interface explorations are preserved in [docs/design-concepts.html](docs/design-concepts.html) as design history, not as the current product specification.

## Security

Generated tools are local zsh executables. New and imported tools remain inert until you review and approve their exact source and working directory. An opt-in setting can automatically approve later provider-written revisions to tools you already approved; automatic repairs still stop for review. Approved code runs with Bar Tender's local process permissions and is not contained by a security sandbox. See [SECURITY.md](SECURITY.md) for the trust model and private vulnerability reporting guidance.

See [PRIVACY.md](PRIVACY.md) for local data and network behavior, [SUPPORT.md](SUPPORT.md) for support routes, [CHANGELOG.md](CHANGELOG.md) for version history, and [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md) for provider icon attribution and trademark notices.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md) before opening a pull request.

## License

Bar Tender is available under the [MIT License](LICENSE).
