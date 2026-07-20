# Security Policy

## Supported versions

Bar Tender is pre-release software. Security fixes are currently made on the latest revision of `main` only.

## Reporting a vulnerability

Please do not open a public issue for a suspected vulnerability. Use GitHub's private vulnerability reporting for this repository. If that feature is unavailable, contact the maintainer privately through the contact method on their GitHub profile.

Include the affected revision, reproduction steps, impact, and any suggested mitigation. Do not include real credentials, private keys, personal files, or destructive proof-of-concept payloads.

## Generated-tool trust model

Bar Tender asks locally installed AI CLIs to generate zsh programs. A generated program is stored but does not execute until the user reviews and explicitly approves its exact source and working directory. Editing either revokes approval.

Approved generated programs execute locally with the permissions of the Bar Tender process. Syntax validation and basic policy checks are safeguards, not a security sandbox. Review generated source before approval, particularly filesystem, network, process-launching, and credential-access behavior.
