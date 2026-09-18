import AppKit
import SwiftUI

/// Top-of-window message. Auto-dismissal is owned by `AppModel` so copies in
/// several windows share one timer; this view only reports hover.
struct BannerView: View {
    let banner: BannerMessage
    let onHover: (Bool) -> Void
    let onDismiss: () -> Void

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
        .onHover(perform: onHover)
        .task(id: banner.id) {
            announceForAccessibility()
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
