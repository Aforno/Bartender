import AppKit
import SwiftUI

@main
struct BarTenderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        InterFont.registerIfNeeded()

        // Command-line sensor reports for generated tools run before any app
        // startup so the process exits immediately with the report on stdout.
        if let exitCode = HardwareSensorsCLI.handledExitCode() {
            Foundation.exit(Int32(exitCode))
        }
    }

    var body: some Scene {
        WindowGroup("Bar Tender", id: "main") {
            ContentView()
                .background(MainWindowActionsInstaller(model: appDelegate.model))
                .tint(PremiumStyle.brand)
                .font(.inter(.body))
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.model.store)
                .environmentObject(appDelegate.model.providers)
                .environmentObject(appDelegate.model.runtime)
                .environmentObject(appDelegate.model.preferences)
                .task {
                    // Main window is open: use a regular app activation policy (Dock + menus).
                    // Status items attach only from AppDelegate — a second attach here
                    // used to force an immediate rebuild and defeat the delayed first
                    // registration that avoids the macOS 26 Control Center race.
                    AppDelegate.prepareForMainWindow()
                    AppActions.shared.model = appDelegate.model
                    await appDelegate.model.bootstrap()
                }
        }
        // Menu-bar tools are created in applicationDidFinishLaunching and are
        // independent of the main window. The window opens at launch so the
        // user always sees the app; the tools stay in the menu bar regardless.
        // .defaultLaunchBehavior(.suppressed)
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
        }

        // Manager status item is an AppKit `NSStatusItem` owned by
        // `ManagerStatusItemController` (installed from AppDelegate), not a
        // SwiftUI `MenuBarExtra`.

        Settings {
            SettingsView()
                .tint(PremiumStyle.brand)
                .font(.inter(.body))
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.model.store)
                .environmentObject(appDelegate.model.providers)
                .environmentObject(appDelegate.model.preferences)
        }
    }
}

@MainActor
enum MainWindowRouter {
    /// Opens or focuses the main window using a stored `OpenWindowAction` when
    /// recreation is needed (window fully closed).
    static func open(using openWindow: OpenWindowAction) {
        if focusExistingMainWindow() {
            return
        }
        AppDelegate.prepareForMainWindow()
        openWindow(id: "main")
    }

    /// AppKit-safe path: focus an existing main window, otherwise invoke the
    /// stored `OpenWindowAction` from `AppActions` (set when the window first mounts).
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
        guard let window = NSApp.windows.first(where: isMainWindow) else {
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
                // Capture OpenWindowAction so the AppKit manager menu can
                // recreate the main window after it has been closed.
                AppActions.shared.openWindowAction = {
                    MainWindowRouter.open(using: openWindow)
                }
            }
    }
}
