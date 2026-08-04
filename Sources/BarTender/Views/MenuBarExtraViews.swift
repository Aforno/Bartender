import SwiftUI

/// Compact left-click popover content for the manager status item:
/// prompt, model selector, send/cancel, and generation feedback only.
struct ManagerComposerView: View {
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
                if generation.phase == .failed {
                    ScrollView(.vertical) {
                        generationFeedback(generation)
                            .padding(.trailing, PremiumStyle.space4)
                    }
                    .frame(maxHeight: 180)
                    .scrollIndicators(.automatic)
                } else {
                    generationFeedback(generation)
                }
            }
        }
        .padding(.horizontal, PremiumStyle.space12)
        .padding(.vertical, PremiumStyle.space8)
        .frame(width: 360)
        .fixedSize(horizontal: true, vertical: true)
        .onAppear {
            AppLog.menuBar.info("Opened Bar Tender manager composer")
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
        AppLog.menuBar.info("Submitting manager composer prompt")
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
                .fixedSize(horizontal: false, vertical: true)
        } else if session.phase == .failed {
            Text(session.errorMessage ?? "Generation failed.")
                .font(.inter(.caption))
                .foregroundStyle(.red)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
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
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}
