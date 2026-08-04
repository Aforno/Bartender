import AppKit
import Combine
import Foundation

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

    /// True once `performBootstrap` (via `model.bootstrap`) has finished for diagnostics.
    private(set) var bootstrapCompleted = false

    private var cancellables = Set<AnyCancellable>()
    private var diagnosticsObserver: NSObjectProtocol?
    private var diagnosticsExitTask: Task<Void, Never>?

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

        let launchMode = AppLaunchMode.current
        if launchMode.activatesAppAtLaunch {
            NSApp.activate(ignoringOtherApps: true)
        }

        AppActions.shared.model = model
        // Manager item first (compact permanent anchor), then per-applet items
        // with their delayed registration. Sole attach sites — do not re-attach
        // from the main window `.task`.
        managerStatusItem.install()
        statusItems.attach(model: model)

        installDiagnosticsResponder()

        Task { @MainActor [weak self] in
            guard let self else { return }
            await self.model.bootstrap()
            self.bootstrapCompleted = true
            AppLog.app.info(
                "Bootstrap completed (launchMode=\(String(describing: launchMode), privacy: .public))"
            )

            if MenuBarDiagnosticsCLI.wantsDiagnosticsRun {
                await self.runDiagnosticsAndExitIfRequested()
            }
        }

        // Ensure smoke libraries have one enabled sample so applet items can be validated.
        if MenuBarDiagnosticsCLI.smokeLibraryPath != nil, model.store.applets.isEmpty {
            model.addSampleLibrary()
            // Cap is often 1; ensure at least one enabled tool is visible.
            if let first = model.store.applets.first, !first.enabled {
                model.toggleEnabled(first)
            }
        }

        AppLog.app.info(
            "Application did finish launching (activationPolicy=regular, launchMode=\(String(describing: launchMode), privacy: .public))"
        )
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        // Dock click / explicit reopen after a silent login launch.
        if !flag || NSApp.windows.allSatisfy({ !MainWindowRouter.isMainWindow($0) || !$0.isVisible }) {
            _ = MainWindowRouter.openMainWindow()
        }
        return true
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        // Stay alive for silent auto-terminates (some SwiftUI launch configs),
        // but never block real user/system quits: ⌘Q, app menu Quit, Dock Quit,
        // or logout/restart (those arrive as kAEQuitApplication).
        if shouldAllowTerminate {
            return .terminateNow
        }
        // Diagnostics mode always terminates when requested.
        if MenuBarDiagnosticsCLI.wantsDiagnosticsRun {
            return .terminateNow
        }
        AppLog.app.info("Ignoring automatic terminate; menu bar tools stay running")
        return .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        if let observer = diagnosticsObserver {
            DistributedNotificationCenter.default().removeObserver(observer)
            diagnosticsObserver = nil
        }
        diagnosticsExitTask?.cancel()
        managerStatusItem.uninstall()
        model.shutdown()
        AppLog.app.info("Application will terminate; runtime tasks cancelled")
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        // Back to regular so status items keep a proper layout slot.
        NSApp.setActivationPolicy(.regular)
        // Diagnostics runs as a short-lived process.
        if MenuBarDiagnosticsCLI.wantsDiagnosticsRun {
            return true
        }
        return false
    }

    /// Activate when presenting the main window from a menu bar action.
    /// No-op when `NSApp` is unavailable (e.g. pure unit-test host without AppKit app bootstrap).
    static func prepareForMainWindow() {
        guard let app = NSApp else { return }
        app.setActivationPolicy(.regular)
        app.activate(ignoringOtherApps: true)
    }

    static func requestQuit() {
        // Reach the shared adaptor instance through the running app delegate.
        if let delegate = NSApp.delegate as? AppDelegate {
            delegate.userRequestedTerminate = true
        }
        NSApp.terminate(nil)
    }

    // MARK: - Menu bar diagnostics

    /// Builds a diagnostics snapshot from the live manager + per-applet items.
    func menuBarDiagnosticsSnapshot() -> MenuBarDiagnosticsSnapshot {
        MenuBarDiagnosticsSnapshot(
            bootstrapCompleted: bootstrapCompleted,
            managerStatusItemInstalled: managerStatusItem.isInstalled,
            managerItemCount: managerStatusItem.managedStatusItemCount,
            appletStatusItemManagerAttached: statusItems.isAttached,
            enabledAppletCount: model.store.enabledApplets.count,
            managedAppletItemCount: statusItems.managedItemCount,
            appletItems: statusItems.appletItemDiagnostics(),
            managerHasVisibleTitleOrImage: managerStatusItem.hasVisibleTitleOrImage,
            managerFrame: managerStatusItem.frameDiagnostic
        )
    }

    private func installDiagnosticsResponder() {
        // Local-machine distributed notification only — no remote control, no secrets.
        diagnosticsObserver = DistributedNotificationCenter.default().addObserver(
            forName: Notification.Name(MenuBarDiagnosticsCLI.requestName),
            object: nil,
            queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            Task { @MainActor in
                let snapshot = self.menuBarDiagnosticsSnapshot()
                let json = (try? snapshot.jsonLine()) ?? #"{"error":"encode_failed"}"#
                DistributedNotificationCenter.default().postNotificationName(
                    Notification.Name(MenuBarDiagnosticsCLI.responseName),
                    object: nil,
                    userInfo: [MenuBarDiagnosticsCLI.responsePayloadKey: json],
                    deliverImmediately: true
                )
            }
        }
    }

    private func runDiagnosticsAndExitIfRequested() async {
        // Wait for per-applet delayed registration plus a short settle period.
        let delay = StatusItemRegistrationTiming.appletInitialDelay + 0.5
        let ns = UInt64(max(0.1, delay) * 1_000_000_000)
        try? await Task.sleep(nanoseconds: ns)

        // If the library is still empty in smoke mode, seed a sample once more.
        if MenuBarDiagnosticsCLI.smokeLibraryPath != nil, model.store.enabledApplets.isEmpty {
            model.addSampleLibrary()
            // Rebuild after sample install.
            statusItems.rebuild(enabled: model.store.enabledApplets)
            statusItems.refreshAll(snapshots: model.runtime.snapshots)
            try? await Task.sleep(nanoseconds: 200_000_000)
        }

        let snapshot = menuBarDiagnosticsSnapshot()
        if let line = try? snapshot.jsonLine() {
            FileHandle.standardOutput.write(Data((line + "\n").utf8))
        } else {
            FileHandle.standardError.write(Data("Failed to encode menu-bar diagnostics.\n".utf8))
        }

        let requireApplet = MenuBarDiagnosticsCLI.smokeLibraryPath != nil
            || !model.store.enabledApplets.isEmpty
        let failures = snapshot.validationFailures(requireEnabledApplet: requireApplet)
        let exitCode: Int32 = failures.isEmpty ? 0 : 1
        if !failures.isEmpty {
            let message = "Menu-bar diagnostics failed: \(failures.joined(separator: "; "))\n"
            FileHandle.standardError.write(Data(message.utf8))
        }

        userRequestedTerminate = true
        // Exit the process after printing — do not leave a headless instance running.
        Foundation.exit(exitCode)
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
