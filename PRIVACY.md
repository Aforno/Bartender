# Privacy

Bar Tender is a local macOS utility. It does not run analytics, advertising, accounts, or telemetry.

## Data stored on this Mac

Bar Tender stores the tool library, preferences, source-bound approval fingerprints, and generated executable artifacts in the user's local Application Support and preferences locations.

Exported libraries contain manifests and generated source. They never contain approval fingerprints. Imported executable tools always require fresh approval.

Sanitized diagnostics include app, system, and provider status, plus counts. They exclude prompts, generated source, filesystem paths, credentials, provider output, and tool output.

## Network and subprocess behavior

- Generation launches the locally installed provider CLI you selected. That CLI may talk to its provider under the provider's own terms and privacy policy.
- Approved generated tools may use the network or local resources according to their exact approved source.
- Built-in HTTP monitors contact the URL you configured.
- Check for Updates makes a user-initiated request to the public GitHub Releases API for `Aforno/Bartender`.
- Bar Tender does not request or store provider API keys. Provider authentication stays with each local CLI.

## Permissions

Notification permission is requested only when you enable an alert. Launch at login is controlled in Settings and may need confirmation in macOS System Settings. Apple Events entitlement is included because approved local tools may launch commands or apps. Generated code still hits macOS permission prompts, plus your source approval or the opt-in auto-approval preference.

For questions or deletion guidance, use the routes in [SUPPORT.md](SUPPORT.md).
