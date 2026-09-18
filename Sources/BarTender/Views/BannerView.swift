import AppKit
import SwiftUI

/// Top-of-window message. Info banners dismiss themselves after a delay that
/// pauses while hovered; error banners stay until the user dismisses them.
struct BannerView: View {
    private static let dismissalDelayNanoseconds: UInt64 = 8_000_000_000

    private struct DismissalKey: Equatable {
        let bannerID: UUID
        let hovering: Bool
    }

    let banner: BannerMessage
    let onDismiss: () -> Void

    @State private var hovering = false

    private var isError: Bool { banner.severity == .error }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: isError ? "exclamationmark.triangle.fill" : "info.circle.fill")
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(isError ? Color.red : PremiumStyle.secondaryText)
                .accessibilityHidden(true)
            Text(banner.text)
                .font(BarTenderFont.body)
                .lineLimit(isError ? 8 : 4)
                .textSelection(.enabled)
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
                .strokeBorder(isError ? Color.red.opacity(0.4) : PremiumStyle.cardStroke, lineWidth: 1)
        )
        .padding(.horizontal, PremiumStyle.space20)
        .frame(maxWidth: 560)
        .accessibilityElement(children: .contain)
        .onHover { hovering = $0 }
        .task(id: banner.id) {
            announceForAccessibility()
        }
        .task(id: DismissalKey(bannerID: banner.id, hovering: hovering)) {
            guard !isError, !hovering else { return }
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
                .announcement: banner.text,
                .priority: (isError ? NSAccessibilityPriorityLevel.high : .medium).rawValue,
            ]
        )
    }
}
