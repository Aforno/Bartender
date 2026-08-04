import CoreGraphics
import Foundation

/// Central configuration for when manager and per-applet status items register
/// with `NSStatusBar`.
///
/// Per-applet items use a short delay on macOS 26 so Control Center can finish
/// tearing down the previous process's displayables. The manager item registers
/// immediately so left-click stays responsive; only add a manager delay if
/// measurements show the same race.
enum StatusItemRegistrationTiming {
    /// Delay before the first per-applet status-item registration.
    /// Tests set this (via `StatusItemManager.initialRegistrationDelay`) to 0.
    static var appletInitialDelay: TimeInterval = 0.75

    /// Delay before manager status-item registration. Kept at 0 unless evidence
    /// shows the manager hits the same Control Center race.
    static var managerInitialDelay: TimeInterval = 0

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
