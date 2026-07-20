# Bar Tender 1.0

Bar Tender turns a plain-language request into a dedicated macOS menu bar tool using an already installed Codex, Claude, or Grok CLI.

This first release includes:

- Review-before-run generated zsh tools with approval bound to the exact source and working directory.
- Provider and model selection with native ChatGPT, Claude, and Grok artwork.
- No generation deadline: long provider runs continue until completion or explicit cancellation.
- Launch at login, library export/import, contextual alerts, diagnostics export, provider setup, and update checks.
- A manager menu that remains usable with many running tools.
- Universal Apple silicon and Intel packaging for macOS 26 and newer.

Important trust note: approved generated code is not sandboxed. It runs with your user privileges and can access local files, network services, commands, and credentials available to local processes. Review source before approval.
