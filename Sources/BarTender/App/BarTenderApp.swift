import AppKit
import SwiftUI

@main
struct BarTenderApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model = AppModel()
    @StateObject private var statusItems = StatusItemManager()

    var body: some Scene {
        WindowGroup("Bar Tender", id: "main") {
            ContentView()
                .tint(PremiumStyle.brand)
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.providers)
                .environmentObject(model.runtime)
                .environmentObject(model.preferences)
                .task {
                    await model.bootstrap()
                    statusItems.attach(model: model)
                    AppActions.shared.model = model
                    AppActions.shared.openWindowAction = {
                        NSApp.activate(ignoringOtherApps: true)
                        for window in NSApp.windows where window.canBecomeKey {
                            window.makeKeyAndOrderFront(nil)
                        }
                    }
                }
                .onReceive(model.$enabledApplets) { enabled in
                    statusItems.rebuild(enabled: enabled)
                }
                .onReceive(model.runtime.$snapshots) { _ in
                    statusItems.refreshAll()
                }
                .onReceive(NotificationCenter.default.publisher(for: .barTenderOpenMainWindow)) { note in
                    if let raw = note.object as? String, let id = UUID(uuidString: raw) {
                        model.selection = id
                    } else {
                        model.selection = nil
                    }
                    NSApp.activate(ignoringOtherApps: true)
                    for window in NSApp.windows where window.canBecomeKey {
                        window.makeKeyAndOrderFront(nil)
                    }
                }
        }
        .defaultSize(width: 1180, height: 760)
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
                .keyboardShortcut(.return, modifiers: [.command])

                Button("Cancel Generation") {
                    model.cancelGeneration()
                }
                .keyboardShortcut(.escape, modifiers: [.command])

                Divider()

                Button("Delete Selected Tool") {
                    model.deleteSelected()
                }
                .keyboardShortcut(.delete, modifiers: [.command])
                .disabled(model.selectedApplet == nil)
            }
        }

        // Manager status item: prompt + library without opening the main window.
        MenuBarExtra("Bar Tender", systemImage: "wineglass") {
            MenuBarManagerMenu()
                .tint(PremiumStyle.brand)
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
                .environmentObject(model)
                .environmentObject(model.store)
                .environmentObject(model.providers)
                .environmentObject(model.preferences)
        }
    }
}
