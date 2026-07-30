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

            if let generation = model.generation {
                generationFeedback(generation)
            }

            if !model.enabledApplets.isEmpty {
                Divider()
                Text("Running tools")
                    .font(.inter(.caption, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .accessibilityAddTraits(.isHeader)

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
        MainWindowRouter.open(using: openWindow)
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

    @ViewBuilder
    private func generationFeedback(_ session: GenerationSession) -> some View {
        if session.phase.isActive {
            Label(session.phase.displayName(for: session.provider), systemImage: "sparkles")
                .font(.inter(.caption))
                .foregroundStyle(.secondary)
                .lineLimit(2)
        } else if session.phase == .failed {
            Label(session.errorMessage ?? "Generation failed.", systemImage: "exclamationmark.triangle.fill")
                .font(.inter(.caption))
                .foregroundStyle(.red)
                .lineLimit(3)
                .help(session.errorMessage ?? "Generation failed.")
        } else if session.phase == .cancelled {
            Label("Generation cancelled", systemImage: "xmark.circle")
                .font(.inter(.caption))
                .foregroundStyle(.secondary)
        } else if session.phase == .succeeded, let manifest = session.resultManifest {
            Label("Ready: \(manifest.name)", systemImage: "checkmark.circle.fill")
                .font(.inter(.caption))
                .foregroundStyle(.green)
                .lineLimit(2)
        }
    }
}
