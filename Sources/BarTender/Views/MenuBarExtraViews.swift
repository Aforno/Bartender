import AppKit
import SwiftUI

/// Window-style menu bar panel with a single message bar for generating new tools.
struct MenuBarManagerMenu: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var providers: AIProviderService
    @EnvironmentObject private var preferences: AppPreferences

    @State private var promptText = ""

    private let suggestions = [
        "Current Music track",
        "Running Docker count",
        "Next calendar event",
        "Downloads folder size"
    ]

    var body: some View {
        ChatComposerBar(
            text: $promptText,
            placeholder: "Generate a menu bar tool…",
            canSend: canCreate,
            isBusy: model.generation?.phase.isActive == true,
            lineLimit: 1...4,
            onSend: {
                Task { await createFromMenuBar() }
            },
            onPlus: {
                if promptText.isEmpty, let first = suggestions.first {
                    promptText = first
                }
            },
            onCancel: {
                model.cancelGeneration()
            }
        ) {
            if preferences.showProviderInComposer {
                ModelSelector(
                    isBusy: model.generation?.phase.isActive == true
                )
            }
        }
        .padding(14)
        .frame(width: 360)
        .onAppear {
            AppLog.menuBar.info("Opened Bar Tender menu bar panel")
        }
    }

    // MARK: - Actions

    private var canCreate: Bool {
        providers.availability.isReady
            && !promptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.generation?.phase.isActive != true
    }

    private func createFromMenuBar() async {
        let prompt = promptText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !prompt.isEmpty else { return }
        AppLog.menuBar.info("Submitting menu bar prompt")
        await model.createNewToolFromPrompt(prompt)
        if model.generation?.phase == .succeeded {
            promptText = ""
        }
    }
}

struct AppletMenuLabel: View {
    let appletID: UUID
    @EnvironmentObject private var store: AppletStore
    @EnvironmentObject private var runtime: AppletRuntimeEngine

    var body: some View {
        let applet = store.applet(id: appletID)
        let snapshot = runtime.snapshots[appletID]
        let title = snapshot?.title ?? applet?.name ?? "Applet"
        let icon = applet?.iconSystemName ?? "questionmark.circle"

        HStack(spacing: 4) {
            Image(systemName: icon)
            Text(TitleRenderer.shortMenuTitle(title))
                .monospacedDigit()
        }
    }
}

struct AppletMenuContent: View {
    let appletID: UUID
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: AppletStore
    @EnvironmentObject private var runtime: AppletRuntimeEngine
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        if let applet = store.applet(id: appletID) {
            let snapshot = runtime.snapshots[appletID] ?? .placeholder(for: applet)

            Text(TitleRenderer.shortMenuTitle(applet.name))
            Text(TitleRenderer.shortMenuTitle(snapshot.statusText))
            Divider()

            ForEach(snapshot.detailLines.prefix(5), id: \.self) { line in
                Text(TitleRenderer.shortMenuTitle(line))
            }

            if applet.kind == .timer || applet.kind == .countdown {
                Divider()
                Button(snapshot.isRunning ? "Pause" : "Start") {
                    runtime.toggleTimer(id: applet.id, manifest: applet)
                }
                Button("Reset") {
                    runtime.resetTimer(id: applet.id, manifest: applet)
                }
            }

            Divider()
            Button("Open in Bar Tender") {
                model.selection = applet.id
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }
            Button(applet.enabled ? "Disable" : "Enable") {
                model.toggleEnabled(applet)
            }
        } else {
            Text("Applet unavailable")
        }
    }
}
