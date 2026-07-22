import AppKit
import SwiftUI

/// Window-style menu bar panel with a single message bar for generating new tools.
struct MenuBarManagerMenu: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var providers: AIProviderService
    @EnvironmentObject private var preferences: AppPreferences
    @Environment(\.openWindow) private var openWindow

    @State private var promptText = ""

    private let suggestions = [
        "Current Music track",
        "Running Docker count",
        "Next calendar event",
        "Downloads folder size"
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: PremiumStyle.space8) {
            ChatComposerBar(
                text: $promptText,
                placeholder: "Generate a menu bar tool…",
                canSend: canCreate,
                isBusy: model.generation?.phase.isActive == true,
                compact: true,
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

            if !model.enabledApplets.isEmpty {
                Divider()
                Text("Running tools")
                    .font(.inter(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)

                ScrollView {
                    LazyVStack(spacing: 2) {
                        ForEach(model.enabledApplets) { applet in
                            Button {
                                open(applet)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: applet.iconSystemName)
                                        .frame(width: 16)
                                    Text(applet.name)
                                        .lineLimit(1)
                                    Spacer()
                                    Text(model.runtime.snapshots[applet.id]?.title ?? "Waiting")
                                        .foregroundStyle(.secondary)
                                        .lineLimit(1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityIdentifier("manager-tool.\(applet.id.uuidString)")
                        }
                    }
                }
                .frame(maxHeight: 210)
            }

            Divider()
            HStack {
                Button("Open Bar Tender", action: openMainWindow)
                Button("Provider Setup…") {
                    model.showingProviderSetup = true
                    openMainWindow()
                }
                Spacer()
                Button("Quit and Stop Tools") {
                    NSApp.terminate(nil)
                }
            }
            .font(.inter(.caption))

            Text("Closing the window keeps tools running; quitting stops them.")
                .font(.inter(.caption2))
                .foregroundStyle(.tertiary)
        }
        .padding(.horizontal, PremiumStyle.space12)
        .padding(.vertical, PremiumStyle.space8)
        .frame(width: 360)
        .onAppear {
            AppLog.menuBar.info("Opened Bar Tender menu bar panel")
        }
    }

    private func open(_ applet: AppletManifest) {
        model.selection = applet.id
        openMainWindow()
    }

    private func openMainWindow() {
        openWindow(id: "main")
        NSApp.activate(ignoringOtherApps: true)
        NSApp.windows.first(where: \.canBecomeKey)?.makeKeyAndOrderFront(nil)
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
