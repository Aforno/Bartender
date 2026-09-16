import AppKit
import SwiftUI

/// Process entry so `--sensors` / `--sensors-json` never construct `AppDelegate`
/// or `AppModel` (those load `applets.json` and Combine subscriptions).
@main
enum BarTenderMain {
    static func main() {
        if let exitCode = HardwareSensorsCLI.handledExitCode() {
            Foundation.exit(Int32(exitCode))
        }
        BarTenderApp.main()
    }
}

struct BarTenderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        WindowGroup("Bar Tender", id: "main") {
            ContentView()
                .background(MainWindowActionsInstaller(model: appDelegate.model))
                .tint(PremiumStyle.brand)
                .font(BarTenderFont.body)
                .foregroundStyle(PremiumStyle.primaryText)
                .preferredColorScheme(.dark)
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.model.store)
                .environmentObject(appDelegate.model.providers)
                .environmentObject(appDelegate.model.runtime)
                .environmentObject(appDelegate.model.preferences)
                .task {
                    // Status items attach only from AppDelegate. A second attach
                    // here used to defeat the delayed first registration.
                    if AppLaunchMode.current.activatesAppAtLaunch {
                        AppDelegate.prepareForMainWindow()
                    } else {
                        NSApp.setActivationPolicy(.regular)
                    }
                    AppActions.shared.model = appDelegate.model
                    await appDelegate.model.bootstrap()
                }
        }
        .defaultLaunchBehavior(AppLaunchMode.current.showsMainWindowAtLaunch ? .automatic : .suppressed)
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tool") {
                    appDelegate.model.beginNewTool()
                }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(appDelegate.model.generation?.phase.isActive == true)
            }
            CommandMenu("Tool") {
                Button(appDelegate.model.selectedApplet == nil ? "Build New Tool from Prompt" : "Update Selected Tool from Prompt") {
                    Task { await appDelegate.model.createFromPrompt() }
                }
                .disabled(
                    appDelegate.model.generation?.phase.isActive == true
                        || appDelegate.model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !appDelegate.model.providers.availability.isReady
                )

                Button("Cancel Generation") {
                    appDelegate.model.cancelGeneration()
                }
                .keyboardShortcut(.escape, modifiers: [.command])
                .disabled(appDelegate.model.generation?.phase.isActive != true)

                Divider()

                Button("Delete Selected Tool") {
                    appDelegate.model.deleteSelected()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(appDelegate.model.selectedApplet == nil || appDelegate.model.generation?.phase.isActive == true)
            }
            // Route standard Quit through requestQuit so it matches the menu-bar
            // "Quit and Stop Tools" path and always marks a user-initiated exit.
            CommandGroup(replacing: .appTermination) {
                Button("Quit Bar Tender") {
                    AppDelegate.requestQuit()
                }
                .keyboardShortcut("q", modifiers: [.command])
            }

            // Capture OpenWindowAction at menu-build time so "Open Bar Tender"
            // works after a silent login launch that never mounted the main window.
            RegisterOpenWindowCommands()
        }

        // Manager status item is an AppKit `NSStatusItem` owned by
        // `ManagerStatusItemController` (installed from AppDelegate), not a
        // SwiftUI `MenuBarExtra`.

        Settings {
            SettingsView()
                .tint(PremiumStyle.brand)
                .font(BarTenderFont.body)
                .foregroundStyle(PremiumStyle.primaryText)
                .preferredColorScheme(.dark)
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.model.store)
                .environmentObject(appDelegate.model.providers)
                .environmentObject(appDelegate.model.preferences)
        }
    }
}

@MainActor
enum MainWindowRouter {
    static func open(using openWindow: OpenWindowAction) {
        if focusExistingMainWindow() {
            return
        }
        AppDelegate.prepareForMainWindow()
        openWindow(id: "main")
    }

    @discardableResult
    static func openMainWindow() -> Bool {
        if focusExistingMainWindow() {
            return true
        }
        AppDelegate.prepareForMainWindow()
        if let open = AppActions.shared.openWindowAction {
            open()
            return true
        }
        AppLog.app.error("Cannot open main window: no existing window and no OpenWindowAction")
        return false
    }

    @discardableResult
    private static func focusExistingMainWindow() -> Bool {
        AppDelegate.prepareForMainWindow()
        // Unit-test hosts may not have a shared NSApplication; treat as no window.
        guard let app = NSApp else { return false }
        guard let window = app.windows.first(where: isMainWindow) else {
            return false
        }
        if window.isMiniaturized {
            window.deminiaturize(nil)
        }
        window.makeKeyAndOrderFront(nil)
        return true
    }

    static func isMainWindow(_ window: NSWindow) -> Bool {
        window.identifier?.rawValue.hasPrefix("main-AppWindow") == true
            || (window.title == "Bar Tender"
                && window.identifier?.rawValue != "com_apple_SwiftUI_Settings_window")
    }
}

private struct MainWindowActionsInstaller: View {
    @Environment(\.openWindow) private var openWindow
    let model: AppModel

    var body: some View {
        Color.clear
            .frame(width: 0, height: 0)
            .accessibilityHidden(true)
            .onAppear {
                AppActions.shared.model = model
                AppActions.shared.openWindowAction = {
                    MainWindowRouter.open(using: openWindow)
                }
            }
            .onReceive(NotificationCenter.default.publisher(for: .bartenderOpenMainWindow)) { _ in
                MainWindowRouter.open(using: openWindow)
            }
    }
}

extension Notification.Name {
    /// Posted when AppKit needs the main window but `OpenWindowAction` may not
    /// yet be installed (first open after a silent launch). A live main-window
    /// view handles it; otherwise `AppActions` falls back to the stored action.
    static let bartenderOpenMainWindow = Notification.Name("io.github.aforno.bartender.v2.openMainWindow")
}

/// Registers `OpenWindowAction` from a one-shot view task so command-menu
/// evaluation does not mutate `AppActions` as a side effect of `body`.
private struct RegisterOpenWindowCommands: Commands {
    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            OpenBarTenderWindowCommand()
        }
    }
}

private struct OpenBarTenderWindowCommand: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open Bar Tender Window") {
            AppDelegate.prepareForMainWindow()
            openWindow(id: "main")
        }
        .keyboardShortcut("o", modifiers: [.command, .option, .shift])
        .task {
            AppActions.shared.installOpenWindowAction {
                AppDelegate.prepareForMainWindow()
                openWindow(id: "main")
            }
        }
    }
}
