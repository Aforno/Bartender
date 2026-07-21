# Security Policy

## Supported versions

Before the first public release, security fixes are made on the latest revision of `main`. After release, fixes target the latest published version and `main`.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's private vulnerability reporting for this repository. If that feature is unavailable, contact the maintainer privately through the contact method on their GitHub profile.

Include the affected revision, reproduction steps, impact, and any suggested mitigation. Do not include real credentials, private keys, personal files, or destructive proof-of-concept payloads.

## Generated-tool trust model

Bar Tender asks locally installed AI CLIs to generate zsh programs. A generated program is stored but does not execute until the user reviews and explicitly approves its exact source and working directory. Editing either revokes approval.

After approval, Bar Tender performs one real execution check. If it fails or returns `healthy=false`, the bounded failure message or output status/title is passed to the selected AI provider CLI as untrusted diagnostic data so the provider can propose an in-place repair. A changed replacement is not executed until the user reviews and approves its new exact source.

Approved generated programs execute locally with the permissions of the Bar Tender process. Syntax validation and basic policy checks are safeguards, not a security sandbox. Review generated source before approval, particularly filesystem, network, process-launching, and credential-access behavior.

Generated tools receive an explicit environment allowlist (`HOME`, user identity, shell/path, temporary-directory, locale, terminal, and `NO_COLOR` values). Bar Tender does not deliberately forward inherited API keys or GitHub tokens. This limits accidental inheritance; it does not prevent approved code from reading files, using the network, launching other local commands, or reaching credentials otherwise available to the user account.
