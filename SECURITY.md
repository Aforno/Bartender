# Security Policy

## Supported versions

Before the first public release, security fixes go on the latest revision of `main`. After release, fixes target the latest published version and `main`.

## Reporting a vulnerability

Do not open a public issue for a suspected vulnerability. Use GitHub's private vulnerability reporting for this repository. If that feature is unavailable, contact the maintainer privately through the contact method on their GitHub profile.

Include the affected revision, reproduction steps, impact, and any suggested mitigation. Do not include real credentials, private keys, personal files, or destructive proof-of-concept payloads.

## Generated-tool trust model

Bar Tender asks locally installed AI CLIs to generate zsh programs. A new or imported generated program is stored but does not execute until you review and explicitly approve its exact source and working directory. Editing either invalidates that source-bound fingerprint.

Settings includes an opt-in option to automatically approve provider-written edits to a generated tool you previously approved. When enabled, Bar Tender records approval for the revised exact source and immediately performs its first-run check, without another source review. This option does not approve new tools, imported tools, edits to tools that have never been approved, or provider-generated automatic repairs.

After approval, Bar Tender performs one real execution check. If it fails or returns `healthy=false`, the bounded failure message or output status/title is passed to the selected AI provider CLI as untrusted diagnostic data so the provider can propose an in-place repair. A changed automatic repair is not executed until you review and approve its new exact source.

Approved generated programs execute locally with the permissions of the Bar Tender process. Syntax validation and the `sudo` / `powermetrics` policy patterns are user-facing safeguards, not a security sandbox. They do not run under `sandbox-exec`. Review generated source before approval, especially filesystem, network, process-launching, and credential-access behavior.

Generated tools, approved shell applets, and git status probes receive an explicit environment allowlist: `HOME`, user identity, shell/path, temporary-directory, locale, terminal, and `NO_COLOR` values. Git probes also set `GIT_OPTIONAL_LOCKS=0` and `GIT_TERMINAL_PROMPT=0`, and invoke git with `core.fsmonitor` disabled. Bar Tender does not deliberately forward inherited API keys or GitHub tokens. Local AI CLIs still receive the full login environment so they can use their own credentials.

That limits accidental inheritance. It does not stop approved code from reading files, using the network, launching other local commands, or reaching credentials otherwise available to the user account.

Approval fingerprints join kind, exact source/command, and working directory with a NUL delimiter. Command and working-directory values that contain NUL cannot be approved. Restoring a captured approval snapshot after a failed import is an exact-content rollback of that snapshot, not a merge of potentially colliding fingerprints.
