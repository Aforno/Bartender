import SwiftUI

/// Shared message input used by the main window and menu bar panel.
/// Compact raised input aligned with AgentNotch's window controls.
struct ChatComposerBar<Accessory: View>: View {
    @Binding var text: String
    var placeholder: String = "Message Bar Tender"
    var canSend: Bool
    var isBusy: Bool = false
    var compact: Bool = false
    var lineLimit: ClosedRange<Int> = 1...6
    var submitHelp: String = "Generate tool (⌘↩)"
    var onSend: () -> Void
    var onPlus: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    @ViewBuilder var accessory: () -> Accessory

    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    /// Target single-line height (controls + vertical padding).
    private var controlSize: CGFloat { 26 }
    private var barRadius: CGFloat { PremiumStyle.cardRadius }

    var body: some View {
        HStack(alignment: .center, spacing: compact ? 8 : 10) {
            if let onPlus {
                Button {
                    onPlus()
                    focused = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(PremiumStyle.secondaryText)
                        .frame(width: controlSize, height: controlSize)
                        .background(
                            PremiumStyle.raisedStrong,
                            in: RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous)
                        )
                        .contentShape(RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous))
                }
                .buttonStyle(.plain)
                .disabled(isBusy)
                .help("Insert a prompt suggestion")
                .accessibilityLabel("Insert a prompt suggestion")
                .accessibilityIdentifier("prompt-suggestion")
            }

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(BarTenderFont.body)
                        .foregroundStyle(PremiumStyle.tertiaryText)
                        .lineLimit(1)
                }

                TextField("", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(BarTenderFont.body)
                    .foregroundStyle(PremiumStyle.primaryText)
                    .lineLimit(lineLimit)
                    .focused($focused)
                    .disabled(isBusy)
                    .frame(minHeight: controlSize, alignment: .center)
                    .onSubmit {
                        guard canSend else { return }
                        onSend()
                    }
                    .accessibilityLabel(placeholder)
                    .accessibilityIdentifier("tool-prompt")
            }

            accessory()
                .fixedSize()

            if isBusy, let onCancel {
                cancelButton(onCancel)
            } else {
                sendButton
            }
        }
        .padding(.horizontal, PremiumStyle.space8)
        .padding(.vertical, 6)
        .frame(minHeight: compact ? 38 : 42)
        .background(barBackground, in: RoundedRectangle(cornerRadius: barRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: barRadius, style: .continuous)
                .strokeBorder(focused ? Color.white.opacity(0.18) : barStroke, lineWidth: 1)
        )
        .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: focused)
    }

    // MARK: - Controls


    private var sendButton: some View {
        Button(action: onSend) {
            Image(systemName: "arrow.up")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(sendForeground)
                .frame(width: controlSize, height: controlSize)
                .background(
                    sendBackground,
                    in: RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .disabled(!canSend)
        .keyboardShortcut(.return, modifiers: [.command])
        .help(submitHelp)
        .accessibilityLabel(submitHelp)
        .accessibilityIdentifier("submit-tool-prompt")
        .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: canSend)
    }

    private func cancelButton(_ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: "stop.fill")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(PremiumStyle.primaryText)
                .frame(width: controlSize, height: controlSize)
                .background(
                    PremiumStyle.raisedStrong,
                    in: RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous)
                )
        }
        .buttonStyle(.plain)
        .help("Cancel")
        .accessibilityLabel("Cancel generation")
        .accessibilityIdentifier("cancel-generation")
    }

    // MARK: - Chrome

    private var barBackground: Color {
        PremiumStyle.raised
    }

    private var barStroke: Color {
        PremiumStyle.cardStroke
    }

    private var sendBackground: Color {
        canSend ? PremiumStyle.raisedStrong : Color.white.opacity(0.035)
    }

    private var sendForeground: Color {
        canSend ? PremiumStyle.primaryText : PremiumStyle.tertiaryText
    }
}

extension ChatComposerBar where Accessory == EmptyView {
    init(
        text: Binding<String>,
        placeholder: String = "Message Bar Tender",
        canSend: Bool,
        isBusy: Bool = false,
        compact: Bool = false,
        lineLimit: ClosedRange<Int> = 1...6,
        onSend: @escaping () -> Void,
        onPlus: (() -> Void)? = nil,
        onCancel: (() -> Void)? = nil
    ) {
        self.init(
            text: text,
            placeholder: placeholder,
            canSend: canSend,
            isBusy: isBusy,
            compact: compact,
            lineLimit: lineLimit,
            onSend: onSend,
            onPlus: onPlus,
            onCancel: onCancel,
            accessory: { EmptyView() }
        )
    }
}

/// Compact model selector for the composer bar.
/// Lists concrete model IDs from ready CLIs (e.g. grok-4.5, gpt-5.6-sol), not providers.
struct ModelSelector: View {
    @EnvironmentObject private var providers: AIProviderService
    var isBusy: Bool = false
    var compact: Bool = true

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        Menu {
            let models = providers.selectableModels
            if models.isEmpty {
                Text("No models available")
            } else {
                ForEach(groupedProviders(from: models), id: \.self) { provider in
                    Section {
                        ForEach(models.filter { $0.provider == provider }) { model in
                            Button {
                                providers.selectModel(model)
                            } label: {
                                modelRow(model)
                            }
                            .accessibilityIdentifier("model-option.\(provider.rawValue).\(model.modelID)")
                        }
                    } header: {
                        Label {
                            Text(provider.displayName)
                        } icon: {
                            ProviderIcon(provider: provider, size: 14)
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                ProviderIcon(provider: providers.selectedModel.provider, size: compact ? 14 : 16)

                Text(providers.selectedModel.shortLabel)
                    .font(BarTenderFont.control)
                    .foregroundStyle(Color.white.opacity(hovering ? 0.84 : 0.68))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.white.opacity(hovering ? 0.68 : 0.50))
            }
            .padding(.horizontal, compact ? PremiumStyle.space8 : PremiumStyle.space12)
            .padding(.vertical, compact ? PremiumStyle.rowInsetV : PremiumStyle.space8)
            .background(
                hovering ? PremiumStyle.raisedStrong : Color.clear,
                in: RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(isBusy)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: hovering)
        .help("Choose model")
        .accessibilityLabel("Model")
        .accessibilityValue(providers.selectedModel.displayName)
        .accessibilityIdentifier("model-picker")
    }

    @ViewBuilder
    private func modelRow(_ model: AIModelOption) -> some View {
        let selected = providers.selectedModel.id == model.id
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            ProviderIcon(provider: model.provider, size: 16)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(model.displayName)
                    if model.isDefault {
                        Text("Default")
                            .font(.inter(.caption2))
                            .foregroundStyle(.secondary)
                    }
                }
                if let description = model.description, !description.isEmpty {
                    Text(description)
                        .font(.inter(.caption))
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                } else {
                    Text(model.modelID)
                        .font(.caption.monospaced())
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 12)
            if selected {
                Image(systemName: "checkmark")
                    .font(.caption.weight(.semibold))
            }
        }
    }

    private func groupedProviders(from models: [AIModelOption]) -> [AIProvider] {
        // Preserve provider enum order, only include groups that have models.
        AIProvider.allCases.filter { provider in
            models.contains { $0.provider == provider }
        }
    }
}
