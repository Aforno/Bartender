import AppKit
import SwiftUI

struct SetupErrorView: View {
    @EnvironmentObject private var providers: AIProviderService
    let onRecheck: () -> Void

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                HStack(spacing: 12) {
                Image(systemName: "wineglass")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(PremiumStyle.primaryText)
                    .frame(width: 32, height: 32)
                    .background(
                        PremiumStyle.raisedStrong,
                        in: RoundedRectangle(cornerRadius: PremiumStyle.controlRadius, style: .continuous)
                    )

                VStack(alignment: .leading, spacing: 3) {
                    Text("Local AI providers")
                        .font(BarTenderFont.display)
                        .accessibilityAddTraits(.isHeader)

                    Text("Bar Tender uses local AI CLIs to create and revise tools. Review their status below; generation needs at least one installed, signed-in, enabled provider. Bar Tender never asks for API keys.")
                        .font(BarTenderFont.caption)
                        .foregroundStyle(PremiumStyle.secondaryText)
                        .frame(maxWidth: 520)
                }
                }

                VStack(spacing: 0) {
                    ForEach(Array(AIProvider.allCases.enumerated()), id: \.element) { index, provider in
                        if index > 0 { BarTenderHairline(leadingInset: 46) }
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
                .font(BarTenderFont.caption)
                .foregroundStyle(PremiumStyle.secondaryText)
                .frame(maxWidth: 560, alignment: .leading)

                GeneratedCodeTrustDisclosure(compact: true)
                    .frame(maxWidth: 560, alignment: .leading)

                HStack(spacing: 12) {
                    Button("Recheck providers") {
                        onRecheck()
                    }
                    .buttonStyle(BarTenderPillButtonStyle())
                    .keyboardShortcut(.defaultAction)

                    Button("Copy setup tips") {
                        let tip = AIProvider.allCases
                            .map { "\($0.displayName): \($0.loginCommand)" }
                            .joined(separator: "\n")
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(tip, forType: .string)
                    }
                    .buttonStyle(BarTenderPillButtonStyle())
                }
            }
            .padding(PremiumStyle.contentMargin)
            .frame(maxWidth: .infinity)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(PremiumStyle.canvas)
        .foregroundStyle(PremiumStyle.primaryText)
        .deepBlackWindowSurface()
    }

    private func providerRow(_ provider: AIProvider) -> some View {
        let enabled = providers.isProviderEnabled(provider)
        let status = providers.status(for: provider)
        return HStack(alignment: .center, spacing: 12) {
            ProviderIcon(provider: provider, size: 24)

            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(provider.displayName)
                        .font(.system(size: 13, weight: .medium))
                    Spacer()
                    statusBadge(status, enabled: enabled)
                }
                if !enabled {
                    Text("Disabled in Settings")
                        .font(.inter(.caption))
                        .foregroundStyle(PremiumStyle.secondaryText)
                    Text("Enable this provider in Settings → Providers to use it for generation.")
                        .font(.inter(.caption2))
                        .foregroundStyle(PremiumStyle.secondaryText)
                        .lineLimit(2)
                } else {
                    switch status {
                    case .checking:
                        Text("Checking…")
                            .font(.inter(.caption))
                            .foregroundStyle(PremiumStyle.secondaryText)
                    case .ready(let install):
                        Text(install.version)
                            .font(.inter(.caption))
                            .foregroundStyle(PremiumStyle.secondaryText)
                            .lineLimit(1)
                        Text(install.authSummary)
                            .font(.inter(.caption2))
                            .foregroundStyle(PremiumStyle.secondaryText)
                            .lineLimit(1)
                    case .unavailable(let issue):
                        Text(issue.title(for: provider))
                            .font(.inter(.caption))
                            .foregroundStyle(PremiumStyle.secondaryText)
                        Text(issue.recoverySuggestion(for: provider))
                            .font(.inter(.caption2))
                            .foregroundStyle(PremiumStyle.secondaryText)
                            .lineLimit(2)
                    }
                }
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityIdentifier("provider-status.\(provider.rawValue)")
        .padding(.horizontal, PremiumStyle.space16)
        .padding(.vertical, PremiumStyle.space12)
    }

    private func statusBadge(_ status: ProviderAvailability, enabled: Bool) -> some View {
        let (text, color): (String, Color) = {
            guard enabled else { return ("Off", .secondary) }
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
