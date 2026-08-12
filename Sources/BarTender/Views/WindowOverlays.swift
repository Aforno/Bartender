import AppKit
import SwiftUI

struct ProviderSetupSheet: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SetupErrorView {
            Task { await model.refreshProviders() }
        }
        .overlay(alignment: .topTrailing) {
            Button("Done") { dismiss() }
                .buttonStyle(BarTenderPillButtonStyle())
                .keyboardShortcut(.cancelAction)
                .padding(PremiumStyle.space16)
        }
        .frame(minWidth: 680, minHeight: 560)
    }
}

struct BannerView: View {
    private static let dismissalDelayNanoseconds: UInt64 = 8_000_000_000

    let text: String
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "info.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(PremiumStyle.secondaryText)
                .accessibilityHidden(true)
            Text(text)
                .font(BarTenderFont.body)
                .lineLimit(4)
            Spacer(minLength: 8)
            Button(action: onDismiss) {
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
        .padding(.vertical, 9)
        .background(PremiumStyle.raisedStrong, in: RoundedRectangle(cornerRadius: PremiumStyle.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PremiumStyle.cardRadius, style: .continuous)
                .strokeBorder(PremiumStyle.cardStroke, lineWidth: 1)
        )
        .padding(.horizontal, PremiumStyle.space20)
        .frame(maxWidth: 560)
        .accessibilityElement(children: .contain)
        .task(id: text) {
            announceForAccessibility()
            do {
                try await Task.sleep(nanoseconds: Self.dismissalDelayNanoseconds)
            } catch {
                return
            }
            onDismiss()
        }
    }

    private func announceForAccessibility() {
        guard let application = NSApp else { return }
        NSAccessibility.post(
            element: application,
            notification: .announcementRequested,
            userInfo: [
                .announcement: text,
                .priority: NSAccessibilityPriorityLevel.medium.rawValue,
            ]
        )
    }
}

struct ProviderUnavailableBanner: View {
    let onSetup: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text("Your tools remain available, but creating or updating one needs a ready model provider.")
                .font(BarTenderFont.body)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 8)
            Button("Set Up…", action: onSetup)
                .buttonStyle(BarTenderPillButtonStyle())
        }
        .padding(.horizontal, PremiumStyle.space16)
        .padding(.vertical, 9)
        .background(
            PremiumStyle.raisedStrong,
            in: RoundedRectangle(cornerRadius: PremiumStyle.cardRadius, style: .continuous)
        )
        .overlay(
            RoundedRectangle(cornerRadius: PremiumStyle.cardRadius, style: .continuous)
                .strokeBorder(Color.orange.opacity(0.35), lineWidth: 1)
        )
        .padding(.horizontal, PremiumStyle.space20)
        .frame(maxWidth: 620)
        .accessibilityElement(children: .contain)
    }
}
