import AppKit
import Combine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    /// App-owned model so menu-bar tools work without a main window.
    let model = AppModel()
    /// Per-tool `NSStatusItem`s; attached at launch, not only when WindowGroup mounts.
    let statusItems = StatusItemManager()
    /// Wine-glass manager item: left-click composer popover, right-click menu.
    private(set) lazy var managerStatusItem = ManagerStatusItemController(model: model)

    /// Set when the user chooses Quit so automatic terminate attempts are ignored.
    private(set) var userRequestedTerminate = false

    private var cancellables = Set<AnyCancellable>()

    override init() {
        super.init()
        // Forward model changes so Scene commands (Quit, New Tool, …) re-evaluate
        // `.disabled` / titles after the model moved out of `@StateObject`.
        model.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        // .regular gives NSStatusItem windows a real menu-bar layout slot on
        // macOS 26 (frame y≈screenHeight-22). .accessory leaves them registered
        // but positioned off-screen (y=-17), so the tools never paint.
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)

        AppActions.shared.model = model
        // Manager item first (compact permanent anchor), then per-applet items
        // with their delayed registration. Sole attach sites — do not re-attach
        // from the main window `.task`.
        managerStatusItem.install()
        statusItems.attach(model: model)
        Task { await model.bootstrap() }
        AppLog.app.info("Application did finish launching (activationPolicy=regular)")
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Stay alive for silent auto-terminates (some SwiftUI launch configs),
        // but never block real user/system quits: ⌘Q, app menu Quit, Dock Quit,
        // or logout/restart (those arrive as kAEQuitApplication).
        if shouldAllowTerminate {
            return .terminateNow
        }
        AppLog.app.info("Ignoring automatic terminate; menu bar tools stay running")
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        managerStatusItem.uninstall()
        model.shutdown()
        AppLog.app.info("Application will terminate; runtime tasks cancelled")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Back to regular so status items keep a proper layout slot.
        NSApp.setActivationPolicy(.regular)
        return false
    }

    /// Activate when presenting the main window from a menu bar action.
    static func prepareForMainWindow() {
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
    }

    static func requestQuit() {
        // Reach the shared adaptor instance through the running app delegate.
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.userRequestedTerminate = true
        }
        NSApp.terminate(nil)
    }

    /// True for explicit requestQuit, standard quit menu/⌘Q, Dock quit, and
    /// system logout/restart. False only for silent auto-terminate attempts.
    private var shouldAllowTerminate: Bool {
        if userRequestedTerminate {
            return true
        }
        if let appleEvent = NSAppleEventManager.shared().currentAppleEvent,
           appleEvent.eventClass == AEEventClass(kCoreEventClass),
           appleEvent.eventID == AEEventID(kAEQuitApplication) {
            return true
        }
        // Fallback when terminate is driven by the key-equivalent before the
        // Apple Event is installed as the current event.
        if let event = NSApp.currentEvent,
           event.type == .keyDown,
           event.modifierFlags.intersection(.deviceIndependentFlagsMask).contains(.command),
           event.charactersIgnoringModifiers?.lowercased() == "q" {
            return true
        }
        return false
    }
}
