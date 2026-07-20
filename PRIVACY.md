# Privacy

Bar Tender is a local macOS utility. The project does not operate an analytics, advertising, account, or telemetry service.

## Data stored on this Mac

Bar Tender stores the tool library, preferences, source-bound approval fingerprints, and generated executable artifacts in the user's local Application Support and preferences locations. Exported libraries contain manifests and generated source, but never approval fingerprints. Imported executable tools always require fresh approval.

Sanitized diagnostics include app/system/provider status and counts. They exclude prompts, generated source, filesystem paths, credentials, provider output, and tool output.

## Network and subprocess behavior

- Generation launches the locally installed provider CLI selected by the user. That CLI may communicate with its provider under the provider's own terms and privacy policy.
- Approved generated tools may use the network or local resources according to their reviewed source.
- Built-in HTTP monitors contact the URL configured by the user.
- **Check for Updates** makes a user-initiated request to the public GitHub Releases API for `Aforno/Bartender`.
- Bar Tender does not request or store provider API keys. Provider authentication remains owned by each local CLI.

## Permissions

Notification permission is requested only when the user enables an alert. Launch at login is controlled by the user in Settings and may require confirmation in macOS System Settings. Apple Events entitlement is included because approved local tools may launch commands or apps; generated code remains subject to macOS permission prompts and the user's approval decision.

For questions or deletion guidance, use the routes in [SUPPORT.md](SUPPORT.md).
