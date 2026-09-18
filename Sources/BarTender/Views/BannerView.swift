import AppKit
import SwiftUI

/// Top-of-window message for `AppModel.bannerMessage`. Auto-dismissal is owned
/// by `AppModel` so copies in several windows share one countdown; each copy
/// only reports whether it is really on screen and whether it is hovered.
struct BannerView: View {
    let banner: BannerMessage

    @EnvironmentObject private var model: AppModel
    @State private var token = UUID()

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
            Button {
                model.bannerMessage = nil
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
        .padding(.vertical, 9)
        .background(PremiumStyle.raisedStrong, in: RoundedRectangle(cornerRadius: PremiumStyle.cardRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: PremiumStyle.cardRadius, style: .continuous)
                .strokeBorder(isError ? Color.red.opacity(0.4) : PremiumStyle.cardStroke, lineWidth: 1)
        )
        .padding(.horizontal, PremiumStyle.space20)
        .frame(maxWidth: 560)
        .accessibilityElement(children: .contain)
        .background {
            BannerPresenceReader { visible, hovered in
                model.updateBannerView(token, visible: visible, hovered: hovered)
            }
        }
        .onDisappear { model.removeBannerView(token) }
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

/// Reports whether the banner's window is actually on screen (not minimized,
/// hidden, fully covered, or on another Space) and whether the pointer is over
/// the banner, including a pointer already resting there when it appears,
/// which SwiftUI's `onHover` misses.
private struct BannerPresenceReader: NSViewRepresentable {
    let onChange: (_ visible: Bool, _ hovered: Bool) -> Void

    func makeNSView(context: Context) -> PresenceView {
        let view = PresenceView()
        view.onChange = onChange
        return view
    }

    func updateNSView(_ view: PresenceView, context: Context) {
        view.onChange = onChange
    }

    final class PresenceView: NSView {
        private struct Presence: Equatable {
            var visible: Bool
            var hovered: Bool
        }

        var onChange: ((_ visible: Bool, _ hovered: Bool) -> Void)?

        private var pointerInside = false
        private var lastReported: Presence?
        private var occlusionObserver: NSObjectProtocol?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            if let occlusionObserver {
                NotificationCenter.default.removeObserver(occlusionObserver)
            }
            occlusionObserver = window.map { window in
                NotificationCenter.default.addObserver(
                    forName: NSWindow.didChangeOcclusionStateNotification,
                    object: window,
                    queue: .main
                ) { [weak self] _ in
                    MainActor.assumeIsolated { self?.refreshFromPointer() }
                }
            }
            refreshFromPointer()
        }

        override func updateTrackingAreas() {
            super.updateTrackingAreas()
            trackingAreas.forEach(removeTrackingArea)
            addTrackingArea(NSTrackingArea(
                rect: .zero,
                options: [.mouseEnteredAndExited, .activeAlways, .inVisibleRect],
                owner: self
            ))
            // Called on layout changes too, so a banner that appears or moves
            // under a resting pointer picks up the hover without mouse movement.
            refreshFromPointer()
        }

        override func mouseEntered(with event: NSEvent) {
            pointerInside = true
            report()
        }

        override func mouseExited(with event: NSEvent) {
            pointerInside = false
            report()
        }

        private func refreshFromPointer() {
            if let window {
                pointerInside = bounds.contains(convert(window.mouseLocationOutsideOfEventStream, from: nil))
            } else {
                pointerInside = false
            }
            report()
        }

        private func report() {
            let visible = window?.occlusionState.contains(.visible) ?? false
            let presence = Presence(visible: visible, hovered: visible && pointerInside)
            guard presence != lastReported else { return }
            lastReported = presence
            onChange?(presence.visible, presence.hovered)
        }
    }
}
