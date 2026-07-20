import SwiftUI

struct ComposerView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var providers: AIProviderService
    @EnvironmentObject private var preferences: AppPreferences

    private let newToolSuggestions = [
        "Show the song currently playing in Music.",
        "Show how many Docker containers are running.",
        "Show today’s next calendar event.",
        "Show the size of my Downloads folder."
    ]

    private let revisionSuggestions = [
        "Make the menu bar title shorter.",
        "Refresh every 10 seconds.",
        "Add more useful details to the menu.",
        "Handle unavailable data more gracefully."
    ]

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                composerContext

                if model.generation?.phase.isActive == true {
                    generationStatus
                }

                ChatComposerBar(
                    text: $model.composerText,
                    placeholder: composerPlaceholder,
                    canSend: canCreate,
                    isBusy: model.generation?.phase.isActive == true,
                    lineLimit: 1...6,
                    submitHelp: model.selectedApplet == nil
                        ? "Build new tool (⌘↩)"
                        : "Update selected tool (⌘↩)",
                    onSend: {
                        Task { await model.createFromPrompt() }
                    },
                    onPlus: {
                        if model.composerText.isEmpty, let first = suggestions.first {
                            model.composerText = first
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

                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 16) {
                        ForEach(suggestions, id: \.self) { suggestion in
                            SuggestionLink(title: suggestion) {
                                model.composerText = suggestion
                            }
                        }
                    }
                    .padding(.vertical, 1)
                }
            }
            .padding(.horizontal, 28)
            .padding(.top, 14)
            .padding(.bottom, 18)
            // Soft backdrop so the pill floats like ChatGPT’s composer
            .background {
                Rectangle()
                    .fill(.ultraThinMaterial)
                    .overlay(alignment: .top) {
                        Divider().opacity(0.55)
                    }
            }
        }
    }

    private var composerContext: some View {
        HStack(spacing: 6) {
            if let applet = model.selectedApplet {
                Text("Editing \(applet.name)")
                    .font(.caption.weight(.semibold))
                Text("· your message updates this tool in place")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 8)
                QuietLink("New Tool") {
                    model.beginNewTool()
                }
                .disabled(model.generation?.phase.isActive == true)
            } else {
                Text("New Tool")
                    .font(.caption.weight(.semibold))
                Text("· your message creates a separate menu bar item")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 4)
    }

    private var suggestions: [String] {
        model.selectedApplet == nil ? newToolSuggestions : revisionSuggestions
    }

    private var composerPlaceholder: String {
        if let applet = model.selectedApplet {
            return "Describe a change to \(applet.name)…"
        }
        return "Describe a new menu bar tool…"
    }

    private var generationStatus: some View {
        HStack(spacing: 10) {
            ProgressView()
                .controlSize(.small)
            VStack(alignment: .leading, spacing: 2) {
                Text(model.generation?.phase.displayName(for: model.generation?.provider) ?? "Generating")
                    .font(.callout.weight(.medium))
                    .contentTransition(.numericText())
                Text(
                    model.generation?.isRevision == true
                        ? "The selected menu bar item will be updated in place."
                        : "A dedicated executable will appear as a new menu bar item."
                )
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
            Button("Cancel") {
                model.cancelGeneration()
            }
            .keyboardShortcut(.escape, modifiers: [])
        }
        .padding(.horizontal, 4)
    }

    private var canCreate: Bool {
        providers.availability.isReady
            && !model.composerText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && model.generation?.phase.isActive != true
    }
}

/// Quiet text link — underlines on hover instead of looking like a button.
private struct QuietLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    init(_ title: String, action: @escaping () -> Void) {
        self.title = title
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .foregroundStyle(Color.secondary)
                .underline(hovering, color: .secondary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.12), value: hovering)
    }
}

/// Plain text suggestion that tints on hover — link-like, not a chip.
private struct SuggestionLink: View {
    let title: String
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.caption)
                .lineLimit(1)
                .foregroundStyle(hovering ? Color.accentColor : Color.secondary)
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.12), value: hovering)
    }
}
