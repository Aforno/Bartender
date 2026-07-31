import AppKit
import SwiftUI

@main
struct BarTenderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var statusItems = StatusItemManager()

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
                .background(MainWindowActionsInstaller(model: model))
                .tint(PremiumStyle.brand)
                .font(.inter(.body))
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.providers)
                .environmentObject(model.runtime)
                .environmentObject(model.preferences)
                .task {
                    appDelegate.model = model
                    statusItems.attach(model: model)
                    AppActions.shared.model = model
                    await model.bootstrap()
                }
        }
        .defaultSize(width: 1180, height: 760)
        .windowToolbarStyle(.unified(showsTitle: false))
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Tool") {
                    model.beginNewTool()
                }
                .keyboardShortcut("n", modifiers: [.command])
                .disabled(model.generation?.phase.isActive == true)
            }
            CommandMenu("Tool") {
                Button(model.selectedApplet == nil ? "Build New Tool from Prompt" : "Update Selected Tool from Prompt") {
                    Task { await model.createFromPrompt() }
                }
                .disabled(
                    model.generation?.phase.isActive == true
                        || model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                        || !model.providers.availability.isReady
                )

                Button("Cancel Generation") {
                    model.cancelGeneration()
                }
                .keyboardShortcut(.escape, modifiers: [.command])
                .disabled(model.generation?.phase.isActive != true)

                Divider()

                Button("Delete Selected Tool") {
                    model.deleteSelected()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(model.selectedApplet == nil || model.generation?.phase.isActive == true)
            }
        }

        // Manager status item: prompt + library without opening the main window.
        MenuBarExtra("Bar Tender", systemImage: "wineglass") {
            MenuBarManagerMenu()
                .tint(PremiumStyle.brand)
                .font(.inter(.body))
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.runtime)
                .environmentObject(model.providers)
                .environmentObject(model.preferences)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView()
                .tint(PremiumStyle.brand)
                .font(.inter(.body))
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.providers)
                .environmentObject(model.preferences)
        }
    }
}

@MainActor
enum MainWindowRouter {
    static func open(using openWindow: OpenWindowAction) {
        if let window = NSApp.windows.first(where: isMainWindow) {
            NSApp.activate(ignoringOtherApps: true)
            if window.isMiniaturized {
                window.deminiaturize(nil)
            }
            window.makeKeyAndOrderFront(nil)
            return
        }

        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
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
