import CoreGraphics
import Foundation

/// Central configuration for when manager and per-applet status items register
/// with `NSStatusBar`.
///
/// Per-applet items delay first registration on macOS 26 so Control Center can
/// finish tearing down the previous process's displayables. The manager stays
/// immediate: delaying it steals the one free post-teardown slot from tools.
enum StatusItemRegistrationTiming {
    /// Delay before the first per-applet status-item registration.
    /// Tests set this (via `StatusItemManager.initialRegistrationDelay`) to 0.
    static var appletInitialDelay: TimeInterval = 0.75

    /// Delay before manager status-item registration. Kept at 0 so the
    /// wine-glass is created immediately. Visibility is forced via
    /// `persistVisible` so a crowded bar cannot hide it in extras.
    /// Tests may set this to 0 explicitly.
    static var managerInitialDelay: TimeInterval = 0

    /// Writes AppKit's persisted visibility flags *before* `autosaveName` is
    /// assigned. AppKit restores those keys at assignment time, so a stale
    /// `false` (drag-off, Control Center extras, VisibleCC=0) hides the item
    /// even when `isVisible` is later set to true.
    static func persistVisible(autosaveName: String) {
        UserDefaults.standard.set(true, forKey: "NSStatusItem Visible \(autosaveName)")
        UserDefaults.standard.set(true, forKey: "NSStatusItem VisibleCC \(autosaveName)")
    }

    /// Wall-clock logging helpers for install diagnostics.
    static func logManagerInstall(
        createdAt: Date,
        autosaveName: String,
        frame: CGRect?
    ) {
        let frameDescription: String
        if let frame {
            frameDescription = "x=\(Int(frame.origin.x)) y=\(Int(frame.origin.y)) w=\(Int(frame.width)) h=\(Int(frame.height))"
        } else {
            frameDescription = "nil"
        }
        AppLog.menuBar.info(
            "Manager status item registered at \(createdAt.timeIntervalSinceReferenceDate, privacy: .public) autosave=\(autosaveName, privacy: .public) frame=(\(frameDescription, privacy: .public))"
        )
    }

    static func logAppletInstall(
        appletName: String,
        createdAt: Date,
        autosaveName: String,
        frame: CGRect?
    ) {
        let frameDescription: String
        if let frame {
            frameDescription = "x=\(Int(frame.origin.x)) y=\(Int(frame.origin.y)) w=\(Int(frame.width)) h=\(Int(frame.height))"
        } else {
            frameDescription = "nil"
        }
        AppLog.menuBar.info(
            "Applet status item '\(appletName, privacy: .public)' registered at \(createdAt.timeIntervalSinceReferenceDate, privacy: .public) autosave=\(autosaveName, privacy: .public) frame=(\(frameDescription, privacy: .public))"
        )
    }
}
