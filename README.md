# Bar Tender

A native macOS app that turns natural-language descriptions into live menu bar applets.

> **Project status:** Bar Tender is pre-release open-source software. It is suitable for development and local evaluation, but downloadable signed and notarized releases are not available yet.

Bar Tender uses an already installed and authenticated **Codex, Claude, or Grok CLI** on your Mac. It does **not** ask for API keys. Each prompt produces a dedicated, reviewable zsh tool artifact that becomes its own live menu bar item.

## What it does

Describe a utility:

- “Watch localhost port 3000 and notify me when it goes offline.”
- “Show CPU and memory usage.”
- “Create a 25-minute focus timer.”
- “Show the current Git branch and number of changed files.”

Select an existing tool in the library and the same composer becomes an editor: your next message is sent with that tool's current manifest and source, then replaces it in place under the same menu bar item. Open **New Tool** (or press `⌘N`) to clear the editing context and build a separate tool.

The selected provider returns a **validated generated-tool manifest** containing the complete source for a one-shot executable. Bar Tender installs it under Application Support, creates its status item immediately, and waits for one explicit source review/approval before execution. Generated tools return structured live menu output (`title`, `status`, `details`, `healthy`, and template `values`).

The library also understands these built-in applet kinds for saved samples and backwards compatibility:

| Kind | Behavior |
| --- | --- |
| `timer` / `countdown` | Countdown with start/pause/reset and optional completion notifications |
| `httpMonitor` | Polls an HTTP(S) URL |
| `portMonitor` | TCP probe of host:port |
| `systemMetrics` | CPU and/or memory usage |
| `gitStatus` | Branch name + changed file count |
| `shellCommand` | Runs only after **explicit user approval** in the inspector; approval is bound to the exact command and working directory. The base tool's availability on this Mac is verified at creation time |

New natural-language requests use `generatedTool` instead of selecting one of these pre-made implementations. Approval is bound to the exact generated source and working directory, so any code edit revokes it automatically.

## Requirements

- macOS 14+
- Swift 5.9+ / Xcode command-line tools
- At least one local AI CLI on your shell `PATH`, signed in:

| Provider | CLI | Auth |
| --- | --- | --- |
| Codex | `codex` | `codex login` |
| Claude | `claude` | `claude auth login` |
| Grok | `grok` | `grok login` |

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

## Test

```bash
swift test
swift build -c release
```

## Provider integration (CLI-only)

Bar Tender discovers each CLI from your login shell environment and probes version + auth.

### Codex
Documented `codex exec` flags only: `--json`, `--sandbox read-only`, `--output-schema`, `--output-last-message`, `--ephemeral`, …

### Claude
Documented print mode: `claude -p --output-format json --json-schema … --tools "" --permission-mode dontAsk --no-session-persistence`

### Grok
Documented single-turn mode: `grok --single … --json-schema … --output-format json --permission-mode dontAsk --tools "" --max-turns 2`

All runs go through `Process` with stdout/stderr capture, cancellation, and a timeout. Auth is never requested as an API key inside the app.

Saved applets are normalized and validated again before startup. Invalid entries are skipped and copied to a recovery sidecar instead of being executed or causing the valid library to disappear.

## App UI

- Natural-language tool generation field
- Provider execution progress + logs
- Live menu bar preview
- Inspector for settings (including shell approval)
- Library of saved applets
- One live AppKit status item per enabled tool, created as soon as generation succeeds, plus a SwiftUI manager `MenuBarExtra`

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
.codex/environments/environment.toml
```

Early interface explorations are preserved in [docs/design-concepts.html](docs/design-concepts.html) as design history, not as the current product specification.

## Security

Generated tools are local zsh executables. They remain inert until you review and approve their exact source and working directory; any edit revokes that approval. Approved code runs with Bar Tender's local process permissions and is not contained by a security sandbox. See [SECURITY.md](SECURITY.md) for the trust model and private vulnerability reporting guidance.

## Contributing

Contributions are welcome. Read [CONTRIBUTING.md](CONTRIBUTING.md) and the [Code of Conduct](CODE_OF_CONDUCT.md) before opening a pull request.

## License

Bar Tender is available under the [MIT License](LICENSE).
