import SwiftUI

/// Compact control for choosing among ready local CLI providers.
struct ProviderPicker: View {
    @EnvironmentObject private var providers: AIProviderService
    var style: Style = .menu

    enum Style {
        case menu
        case segmented
        case labels
    }

    var body: some View {
        switch style {
        case .menu:
            Picker("Provider", selection: $providers.selectedProvider) {
                ForEach(AIProvider.allCases) { provider in
                    Label {
                        HStack {
                            Text(provider.displayName)
                            if providers.status(for: provider).isReady {
                                Text("Ready")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            } else {
                                Text("Unavailable")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: provider.systemImage)
                    }
                    .tag(provider)
                    .disabled(!providers.status(for: provider).isReady && providers.anyProviderReady)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .frame(maxWidth: 140)

        case .segmented:
            Picker("Provider", selection: $providers.selectedProvider) {
                ForEach(AIProvider.allCases) { provider in
                    Text(provider.displayName)
                        .tag(provider)
                        .disabled(!providers.status(for: provider).isReady && providers.anyProviderReady)
                }
            }
            .pickerStyle(.segmented)

        case .labels:
            HStack(spacing: 6) {
                ForEach(AIProvider.allCases) { provider in
                    let ready = providers.status(for: provider).isReady
                    ProviderChip(
                        provider: provider,
                        ready: ready,
                        selected: providers.selectedProvider == provider
                    ) {
                        if ready || !providers.anyProviderReady {
                            providers.selectedProvider = provider
                        }
                    }
                    .disabled(!ready && providers.anyProviderReady)
                    .opacity(ready || !providers.anyProviderReady ? 1 : 0.45)
                }
            }
        }
    }
}

/// A single provider chip with readiness dot, hover highlight, and selection ring.
private struct ProviderChip: View {
    let provider: AIProvider
    let ready: Bool
    let selected: Bool
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Circle()
                    .fill(ready ? Color.green : Color.orange.opacity(0.8))
                    .frame(width: 6, height: 6)
                    .shadow(color: (ready ? Color.green : Color.orange).opacity(0.5), radius: 2)
                Text(provider.displayName)
            }
            .font(.caption.weight(selected ? .semibold : .regular))
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(
                selected
                    ? Color.accentColor.opacity(0.12)
                    : Color.primary.opacity(hovering ? 0.07 : 0.035),
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .strokeBorder(
                        selected ? Color.accentColor.opacity(0.35) : (hovering ? PremiumStyle.chromeStroke : Color.clear),
                        lineWidth: 1
                    )
            )
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.12), value: hovering)
    }
}
