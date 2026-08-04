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
                    AppDelegate.prepareForMainWindow()
                    // Re-attach/rebuild when the main window appears (idempotent).
                    // Primary attach + bootstrap happen in applicationDidFinishLaunching.
                    appDelegate.statusItems.attach(model: appDelegate.model)
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

        // Manager status item: prompt + library without opening the main window.
        MenuBarExtra("Bar Tender", systemImage: "wineglass") {
            MenuBarManagerMenu()
                .tint(PremiumStyle.brand)
                .font(.inter(.body))
                .environmentObject(appDelegate.model)
                .environmentObject(appDelegate.model.store)
                .environmentObject(appDelegate.model.runtime)
                .environmentObject(appDelegate.model.providers)
                .environmentObject(appDelegate.model.preferences)
        }
        .menuBarExtraStyle(.window)

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
    static func open(using openWindow: OpenWindowAction) {
        AppDelegate.prepareForMainWindow()

        if let window = NSApp.windows.first(where: isMainWindow) {
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }

        openWindow(id: "main")
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
    }
}
