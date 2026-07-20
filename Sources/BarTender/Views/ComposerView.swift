import SwiftUI

struct ComposerView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var providers: AIProviderService
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: PremiumStyle.space12) {
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
            // The message box floats on the page — soft lift, no separator bar.
            .shadow(color: .black.opacity(0.07), radius: 14, y: 3)
        }
        .padding(.horizontal, PremiumStyle.contentMargin)
        .padding(.top, PremiumStyle.space12)
        .padding(.bottom, PremiumStyle.space16)
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
        .padding(.horizontal, PremiumStyle.space4)
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
        .padding(.horizontal, PremiumStyle.space4)
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
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

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
        .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: hovering)
    }
}
