import AppKit
import SwiftUI

/// Keeps the content-backed title bar transparent and removes the window shadow
/// only when the window already touches every visible screen edge.
struct WindowChromeConfigurator: NSViewRepresentable {
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        attachWindow(for: view, coordinator: context.coordinator)
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        attachWindow(for: view, coordinator: context.coordinator)
    }

    private func attachWindow(for view: NSView, coordinator: Coordinator) {
        DispatchQueue.main.async {
            coordinator.attach(to: view.window)
        }
    }

    final class Coordinator: NSObject {
        private weak var window: NSWindow?

        func attach(to window: NSWindow?) {
            guard self.window !== window else {
                updateWindowShadow()
                return
            }

            NotificationCenter.default.removeObserver(self)
            self.window = window

            guard let window else { return }
            let center = NotificationCenter.default
            center.addObserver(self, selector: #selector(windowFrameChanged), name: NSWindow.didMoveNotification, object: window)
            center.addObserver(self, selector: #selector(windowFrameChanged), name: NSWindow.didResizeNotification, object: window)
            center.addObserver(self, selector: #selector(windowFrameChanged), name: NSWindow.didChangeScreenNotification, object: window)
            center.addObserver(self, selector: #selector(windowWillEnterFullScreen), name: NSWindow.willEnterFullScreenNotification, object: window)
            center.addObserver(self, selector: #selector(windowFrameChanged), name: NSWindow.didEnterFullScreenNotification, object: window)
            center.addObserver(self, selector: #selector(windowFrameChanged), name: NSWindow.didExitFullScreenNotification, object: window)
            configure(window)
            updateWindowShadow()
        }

        deinit {
            NotificationCenter.default.removeObserver(self)
        }

        @objc private func windowFrameChanged(_ notification: Notification) {
            updateWindowShadow()
        }

        @objc private func windowWillEnterFullScreen(_ notification: Notification) {
            window?.hasShadow = false
        }

        private func configure(_ window: NSWindow) {
            window.styleMask.insert(.fullSizeContentView)
            window.titlebarAppearsTransparent = true
            window.titlebarSeparatorStyle = .none
        }

        private func updateWindowShadow() {
            guard let window else { return }
            let fillsScreen = window.screen.map {
                Self.fillsVisibleScreen(window.frame, visibleFrame: $0.visibleFrame)
            } ?? false
            window.hasShadow = !(window.styleMask.contains(.fullScreen) || fillsScreen)
        }

        private static func fillsVisibleScreen(_ frame: NSRect, visibleFrame: NSRect) -> Bool {
            let tolerance: CGFloat = 1
            return abs(frame.minX - visibleFrame.minX) <= tolerance
                && abs(frame.minY - visibleFrame.minY) <= tolerance
                && abs(frame.maxX - visibleFrame.maxX) <= tolerance
                && abs(frame.maxY - visibleFrame.maxY) <= tolerance
        }
    }
}
