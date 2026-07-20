# Contributing to Bar Tender

Thanks for helping improve Bar Tender.

## Before you start

- Search existing issues before opening a new one.
- For a substantial feature or architectural change, open an issue first so the approach can be discussed.
- Never include API keys, CLI credentials, private prompts, generated tools containing personal data, or other secrets in an issue or pull request.

## Local development

You need macOS 14 or later and Swift 5.9 or later. At least one supported AI CLI is needed only for manual generation testing.

```bash
git clone <your-fork-url>
cd Bartender
swift test
./script/build_and_run.sh --verify
```

The run script builds a local app bundle in `dist/`. That directory is intentionally ignored by Git.

## Pull requests

1. Create a focused branch from `main`.
2. Keep unrelated formatting or refactors out of the change.
3. Add or update tests for behavior changes.
4. Run `swift test` and `swift build -c release`.
5. Describe the user-visible result, test evidence, and any security implications in the pull request.

Changes to generated-tool execution, approval, provider invocation, persistence, or process handling require regression tests. Generated tools must remain inert until their exact source and working directory have been approved by the user.

## Style

- Follow the existing Swift and SwiftUI conventions.
- Prefer small, explicit types and testable services.
- Surface failures to the user instead of silently discarding them.
- Preserve macOS 14 compatibility unless a deliberate platform change has been agreed upon.

By participating, you agree to follow the [Code of Conduct](CODE_OF_CONDUCT.md).
