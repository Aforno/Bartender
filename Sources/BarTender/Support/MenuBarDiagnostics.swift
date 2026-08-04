import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Snapshot of menu-bar infrastructure for packaged-app smoke validation.
struct MenuBarDiagnosticsSnapshot: Equatable, Sendable, Codable {
    var bootstrapCompleted: Bool
    var managerStatusItemInstalled: Bool
    var managerItemCount: Int
    var appletStatusItemManagerAttached: Bool
    var enabledAppletCount: Int
    var managedAppletItemCount: Int
    /// Per managed item: applet name, title state, and live window geometry.
    var appletItems: [AppletItemDiagnostic]
    var managerHasVisibleTitleOrImage: Bool
    var managerFrame: StatusItemFrameDiagnostic = .missing

    struct AppletItemDiagnostic: Equatable, Sendable, Codable {
        var appletID: String
        var name: String
        var titleNonEmpty: Bool
        var titlePreview: String
        var frame: StatusItemFrameDiagnostic = .missing
    }

    /// Captured geometry of the AppKit window that hosts an NSStatusItem button.
    struct StatusItemFrameDiagnostic: Equatable, Sendable, Codable {
        var windowPresent: Bool
        var width: Double
        var height: Double
        var centerOnScreen: Bool
        var nearScreenTop: Bool
        var appearsPaintable: Bool
        var description: String

        static let missing = StatusItemFrameDiagnostic(
            windowPresent: false,
            width: 0,
            height: 0,
            centerOnScreen: false,
            nearScreenTop: false,
            appearsPaintable: false,
            description: "missing-window"
        )

        static func synthetic(paintable: Bool) -> StatusItemFrameDiagnostic {
            StatusItemFrameDiagnostic(
                windowPresent: paintable,
                width: paintable ? 22 : 0,
                height: paintable ? 22 : 0,
                centerOnScreen: paintable,
                nearScreenTop: paintable,
                appearsPaintable: paintable,
                description: paintable ? "synthetic-paintable" : "synthetic-hidden"
            )
        }

        #if canImport(AppKit)
        @MainActor
        static func capture(button: NSStatusBarButton?) -> StatusItemFrameDiagnostic {
            guard let window = button?.window else { return .missing }
            let frame = window.frame
            let center = NSPoint(x: frame.midX, y: frame.midY)
            let screen = window.screen
                ?? NSScreen.screens.first(where: { $0.frame.contains(center) })
            let centerOnScreen = screen?.frame.contains(center) ?? false
            let nearScreenTop: Bool
            if let screen {
                let tolerance = max(64, frame.height * 3)
                nearScreenTop = frame.midY >= screen.frame.maxY - tolerance
                    && frame.midY <= screen.frame.maxY + 4
            } else {
                nearScreenTop = false
            }
            let nonZero = frame.width >= 1 && frame.height >= 1
            let paintable = nonZero && centerOnScreen && nearScreenTop
            let description = String(
                format: "x=%.1f y=%.1f w=%.1f h=%.1f centerOnScreen=%@ nearTop=%@",
                frame.origin.x,
                frame.origin.y,
                frame.width,
                frame.height,
                centerOnScreen ? "true" : "false",
                nearScreenTop ? "true" : "false"
            )
            return StatusItemFrameDiagnostic(
                windowPresent: true,
                width: frame.width,
                height: frame.height,
                centerOnScreen: centerOnScreen,
                nearScreenTop: nearScreenTop,
                appearsPaintable: paintable,
                description: description
            )
        }
        #endif
    }

    /// Machine-readable one-line JSON for CLI / smoke harnesses.
    func jsonLine() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let data = try encoder.encode(self)
        guard let line = String(data: data, encoding: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return line
    }

    /// Human-readable summary for logs.
    var summary: String {
        let appletSummary = appletItems.map { item in
            "\(item.name):title=\(item.titleNonEmpty ? "ok" : "empty"),frame=\(item.frame.appearsPaintable ? "ok" : item.frame.description)"
        }.joined(separator: ", ")
        return [
            "bootstrap=\(bootstrapCompleted)",
            "managerInstalled=\(managerStatusItemInstalled)",
            "managerCount=\(managerItemCount)",
            "managerFrame=\(managerFrame.appearsPaintable ? "ok" : managerFrame.description)",
            "appletAttached=\(appletStatusItemManagerAttached)",
            "enabled=\(enabledAppletCount)",
            "managed=\(managedAppletItemCount)",
            "applets=[\(appletSummary)]"
        ].joined(separator: " ")
    }

    /// Validates infrastructure that smoke tests require.
    func validationFailures(requireEnabledApplet: Bool) -> [String] {
        var failures: [String] = []
        if !bootstrapCompleted {
            failures.append("bootstrap never finished")
        }
        if !managerStatusItemInstalled {
            failures.append("manager status item is not installed")
        }
        if managerItemCount != 1 {
            failures.append("expected exactly 1 manager status item, found \(managerItemCount)")
        }
        if !managerHasVisibleTitleOrImage {
            failures.append("manager status item has no visible title or image")
        }
        if !managerFrame.appearsPaintable {
            failures.append("manager status item frame is not paintable: \(managerFrame.description)")
        }
        if !appletStatusItemManagerAttached {
            failures.append("per-applet status item manager is not attached")
        }
        if requireEnabledApplet {
            if enabledAppletCount < 1 {
                failures.append("expected at least one enabled applet for smoke validation")
            }
            if managedAppletItemCount < 1 {
                failures.append("enabled applet present but no managed status item")
            }
            for item in appletItems where !item.titleNonEmpty {
                failures.append("applet item title unexpectedly empty for \(item.name)")
            }
            for item in appletItems where !item.frame.appearsPaintable {
                failures.append("applet item frame is not paintable for \(item.name): \(item.frame.description)")
            }
        }
        return failures
    }
}

/// Pure sizing policy for the manager composer popover (testable without AppKit layout).
enum ManagerPopoverSizing {
    static let minimumWidth: CGFloat = 340
    static let minimumHeight: CGFloat = 48
    static let maximumWidth: CGFloat = 420
    static let maximumHeight: CGFloat = 360
    static let defaultCompactHeight: CGFloat = 56

    /// Coalesce rapid streaming updates before applying a new popover size.
    static let resizeDebounceNanoseconds: UInt64 = 50_000_000 // 50ms

    /// Clamps a proposed fitting size into the allowed popover bounds.
    static func contentSize(
        fitting: CGSize,
        screenVisibleHeight: CGFloat? = nil
    ) -> CGSize {
        var width = max(fitting.width, minimumWidth)
        width = min(width, maximumWidth)

        var height = max(fitting.height, minimumHeight)
        height = min(height, maximumHeight)
        if let screenVisibleHeight, screenVisibleHeight > 0 {
            // Leave breathing room so long errors never exceed the display.
            let screenCap = max(minimumHeight, screenVisibleHeight * 0.45)
            height = min(height, screenCap)
        }
        return CGSize(width: width, height: height)
    }
}

/// CLI / distributed-notification diagnostics for menu-bar smoke tests.
enum MenuBarDiagnosticsCLI {
    static let diagnosticsFlag = "--menu-bar-diagnostics"
    static let smokeLibraryFlag = "--smoke-library"
    /// Distributed notification names (local machine only; no remote control surface).
    static let requestName = "io.github.aforno.bartender.v2.menuBarDiagnosticsRequest"
    static let responseName = "io.github.aforno.bartender.v2.menuBarDiagnosticsResponse"
    static let responsePayloadKey = "snapshotJSON"

    static var wantsDiagnosticsRun: Bool {
        CommandLine.arguments.contains(diagnosticsFlag)
    }

    /// Optional isolated library directory for smoke runs (`--smoke-library PATH`).
    static var smokeLibraryPath: String? {
        let args = CommandLine.arguments
        guard let index = args.firstIndex(of: smokeLibraryFlag),
              args.index(after: index) < args.endIndex else {
            return nil
        }
        return args[args.index(after: index)]
    }
}
