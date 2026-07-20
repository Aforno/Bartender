import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var providers: AIProviderService
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Group {
            if providers.anyProviderReady || isStillChecking {
                mainWorkspace
            } else {
                SetupErrorView {
                    Task { await model.refreshProviders() }
                }
                .environmentObject(providers)
            }
        }
        .frame(minWidth: 720, minHeight: 500)
        .sheet(isPresented: $model.showingProviderSetup) {
            ProviderSetupSheet()
                .environmentObject(model)
                .environmentObject(providers)
        }
    }

    private var isStillChecking: Bool {
        providers.statuses.values.contains {
            if case .checking = $0 { return true }
            return false
        }
    }

    private var mainWorkspace: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 224, max: 280)
        } detail: {
            VStack(spacing: 0) {
                DetailView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                ComposerView()
                    .background(PremiumStyle.canvas)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .overlay(alignment: .top) {
            if let banner = model.bannerMessage {
                BannerView(text: banner) {
                    model.bannerMessage = nil
                }
                .padding(.top, PremiumStyle.space8)
                .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .animation(reduceMotion ? nil : .snappy, value: model.bannerMessage)
    }
}

private struct ProviderSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SetupErrorView {
            Task { await model.refreshProviders() }
        }
        .overlay(alignment: .topTrailing) {
            Button("Done") { dismiss() }
                .keyboardShortcut(.cancelAction)
                .padding(PremiumStyle.space16)
        }
        .frame(minWidth: 680, minHeight: 560)
    }
}

private struct BannerView: View {
    private static let dismissalDelayNanoseconds: UInt64 = 5_000_000_000

    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(PremiumStyle.brand)
            Text(text)
                .font(.callout)
                .lineLimit(2)
            Spacer(minLength: 8)
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 20, height: 20)
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Dismiss")
            .accessibilityLabel("Dismiss message")
            .accessibilityIdentifier("dismiss-banner")
        }
        .padding(.horizontal, PremiumStyle.space16)
        .padding(.vertical, PremiumStyle.space12)
        .background(PremiumStyle.fieldFill, in: RoundedRectangle(cornerRadius: PremiumStyle.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PremiumStyle.cardRadius, style: .continuous)
                .strokeBorder(PremiumStyle.cardStroke, lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.10), radius: 12, y: 3)
        .padding(.horizontal, PremiumStyle.space20)
        .frame(maxWidth: 560)
        .task(id: text) {
            do {
                try await Task.sleep(nanoseconds: Self.dismissalDelayNanoseconds)
            } catch {
                return
            }
            onDismiss()
        }
    }
}
