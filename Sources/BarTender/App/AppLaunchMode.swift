import Foundation

#if canImport(AppKit)
import AppKit
#endif

/// Testable decision for whether this process should behave as a normal
/// interactive launch or a silent login-item / background start.
enum AppLaunchMode: Equatable, Sendable {
    /// User (or Dock / Finder) launched the app; showing the main window is fine.
    case interactive
    /// Login-item / background launch; only menu-bar infrastructure should start.
    case silentLogin

    /// Resolved once at process start; override only in tests via `setCurrentForTesting`.
    private static let _lock = NSLock()
    private static var _override: AppLaunchMode?
    private static var _resolved: AppLaunchMode?

    /// Current launch mode for this process.
    static var current: AppLaunchMode {
        _lock.lock()
        defer { _lock.unlock() }
        if let override = _override {
            return override
        }
        if let resolved = _resolved {
            return resolved
        }
        let value = resolve()
        _resolved = value
        return value
    }

    /// Whether the main window should appear automatically at launch.
    var showsMainWindowAtLaunch: Bool {
        switch self {
        case .interactive: return true
        case .silentLogin: return false
        }
    }

    /// Whether the app should steal focus with `NSApp.activate` at launch.
    var activatesAppAtLaunch: Bool {
        switch self {
        case .interactive: return true
        case .silentLogin: return false
        }
    }

    /// Pure resolution used by production and unit tests.
    static func resolve(
        arguments: [String] = CommandLine.arguments,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        launchedAsLoginItem: Bool? = nil
    ) -> AppLaunchMode {
        // Explicit CLI / smoke overrides win first.
        if arguments.contains("--interactive-launch") {
            return .interactive
        }
        if arguments.contains("--silent-launch") || arguments.contains("--login-item-launch") {
            return .silentLogin
        }
        if environment["BARTENDER_SILENT_LAUNCH"] == "1" {
            return .silentLogin
        }
        if environment["BARTENDER_SILENT_LAUNCH"] == "0" {
            return .interactive
        }

        let loginItem: Bool
        if let launchedAsLoginItem {
            loginItem = launchedAsLoginItem
        } else {
            loginItem = detectLaunchedAsLoginItem()
        }
        return loginItem ? .silentLogin : .interactive
    }

    /// Detects Launch Services / login-item starts via the Apple Event that
    /// launched the process (`keyAELaunchedAsLogInItem` = `'lgit'`).
    static func detectLaunchedAsLoginItem(
        appleEvent: NSAppleEventDescriptor? = nil
    ) -> Bool {
        #if canImport(AppKit)
        let event = appleEvent ?? NSAppleEventManager.shared().currentAppleEvent
        guard let event else { return false }

        // Platform constant from AERegistry.h (`'lgit'`). Prefer the named
        // constant so a wrong four-character code cannot regress silently.
        if event.paramDescriptor(forKeyword: keyAELaunchedAsLogInItem)?.booleanValue == true {
            return true
        }

        // `keyAELaunchedAsServiceItem` (`'svit'`) — treat as silent as well.
        if event.paramDescriptor(forKeyword: keyAELaunchedAsServiceItem)?.booleanValue == true {
            return true
        }
        #endif
        return false
    }

    // MARK: - Testing

    /// Overrides `current` for the remainder of a test. Pass `nil` to clear.
    static func setCurrentForTesting(_ mode: AppLaunchMode?) {
        _lock.lock()
        _override = mode
        if mode == nil {
            _resolved = nil
        }
        _lock.unlock()
    }
}
