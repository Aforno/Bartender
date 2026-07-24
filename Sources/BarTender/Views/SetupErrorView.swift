import AppKit
import SwiftUI

struct SetupErrorView: View {
    @EnvironmentObject private var providers: AIProviderService
    let onRecheck: () -> Void

    var body: some View {
        VStack(spacing: 22) {
            Image(systemName: "wineglass")
                .font(.system(size: 30, weight: .semibold))
                .foregroundStyle(.white)
                .frame(width: 64, height: 64)
                .background(
                    PremiumStyle.brandGradient,
                    in: RoundedRectangle(cornerRadius: 16, style: .continuous)
                )
                .shadow(color: PremiumStyle.brand.opacity(0.30), radius: 12, y: 3)

            VStack(spacing: 8) {
                Text("Bar Tender needs a local AI CLI")
                    .font(.inter(.title, weight: .semibold))

                Text("Install and sign in to at least one provider: Codex, Claude, Grok, Gemini, or Antigravity. Bar Tender never asks for API keys — it uses CLIs already on your Mac.")
                    .font(.inter(.body))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 520)
            }

            VStack(spacing: 0) {
                ForEach(Array(AIProvider.allCases.enumerated()), id: \.element) { index, provider in
                    if index > 0 { Divider() }
                    providerRow(provider)
                }
            }
            .frame(maxWidth: 560, alignment: .leading)
            .borderedContainer()

            VStack(alignment: .leading, spacing: 8) {
                Label("No OpenAI / Anthropic / xAI API key fields in this app.", systemImage: "key.slash")
                Label("Generation uses documented CLI flags only, via Process.", systemImage: "terminal")
                Label("Generated source is installed locally and shown for review before it can run.", systemImage: "checkmark.shield")
            }
            .font(.inter(.callout))
            .foregroundStyle(.secondary)
            .frame(maxWidth: 560, alignment: .leading)

            GeneratedCodeTrustDisclosure(compact: true)
                .frame(maxWidth: 560, alignment: .leading)

            HStack(spacing: 12) {
                Button("Recheck providers") {
                    onRecheck()
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)

                Button("Copy setup tips") {
                    let tip = AIProvider.allCases
                        .map { "\($0.displayName): \($0.loginCommand)" }
                        .joined(separator: "\n")
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tip, forType: .string)
                }
                .controlSize(.large)
            }
        }
        .padding(PremiumStyle.space40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PremiumStyle.canvas)
    }

    private func providerRow(_ provider: AIProvider) -> some View {
        let status = providers.status(for: provider)
        return HStack(alignment: .center, spacing: 12) {
            ProviderIcon(provider: provider, size: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(provider.displayName)
                        .font(.inter(.headline, weight: .semibold))
                    Spacer()
                    statusBadge(status)
                }
                switch status {
                case .checking:
                    Text("Checking…")
                        .font(.inter(.caption))
                        .foregroundStyle(.secondary)
                case .ready(let install):
                    Text(install.version)
                        .font(.inter(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                    Text(install.authSummary)
                        .font(.inter(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                case .unavailable(let issue):
                    Text(issue.title(for: provider))
                        .font(.inter(.caption))
                        .foregroundStyle(.secondary)
                    Text(issue.recoverySuggestion(for: provider))
                        .font(.inter(.caption2))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("provider-status.\(provider.rawValue)")
        .padding(.horizontal, PremiumStyle.space16)
        .padding(.vertical, PremiumStyle.space12)
    }

    private func statusBadge(_ status: ProviderAvailability) -> some View {
        let (text, color): (String, Color) = {
            switch status {
            case .checking: return ("Checking", .secondary)
            case .ready: return ("Ready", .green)
            case .unavailable: return ("Unavailable", .red)
            }
        }()
        return Text(text)
            .font(.inter(.caption, weight: .semibold))
            .foregroundStyle(color)
    }
}
