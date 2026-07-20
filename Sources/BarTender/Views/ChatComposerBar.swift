import SwiftUI

/// Shared message input used by the main window and menu bar panel.
/// Rounded-rectangle field — a SaaS-style input, not a floating pill.
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

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @FocusState private var focused: Bool

    /// Target single-line height (controls + vertical padding).
    private var controlSize: CGFloat { compact ? 28 : 32 }
    private var barRadius: CGFloat { compact ? 10 : 12 }

    var body: some View {
        HStack(alignment: .center, spacing: compact ? 8 : 10) {
            

            ZStack(alignment: .leading) {
                if text.isEmpty {
                    Text(placeholder)
                        .font(.system(size: compact ? 14 : 15))
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                }

                TextField("", text: $text, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: compact ? 14 : 15))
                    .foregroundStyle(.primary)
                    .lineLimit(lineLimit)
                    .focused($focused)
                    .disabled(isBusy)
                    .frame(minHeight: controlSize, alignment: .center)
                    .onSubmit(onSend)
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
        .padding(.horizontal, compact ? PremiumStyle.space8 : PremiumStyle.space12)
        .padding(.vertical, compact ? PremiumStyle.space4 : PremiumStyle.space8)
        .frame(minHeight: compact ? 40 : 52)
        .background(barBackground, in: RoundedRectangle(cornerRadius: barRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: barRadius, style: .continuous)
                .strokeBorder(focused ? PremiumStyle.brand.opacity(0.55) : barStroke, lineWidth: 1)
        )
        .animation(reduceMotion ? nil : .snappy(duration: 0.15), value: focused)
    }

    // MARK: - Controls


    private var sendButton: some View {
        Button(action: onSend) {
            Image(systemName: "arrow.up")
                .font(.system(size: 13, weight: .bold))
                .foregroundStyle(sendForeground)
                .frame(width: controlSize, height: controlSize)
                .background(sendBackground, in: Circle())
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
                .font(.system(size: 11, weight: .bold))
                .foregroundStyle(Color.primary.opacity(0.75))
                .frame(width: controlSize, height: controlSize)
                .background(
                    colorScheme == .dark
                        ? Color.white.opacity(0.14)
                        : Color.primary.opacity(0.12),
                    in: Circle()
                )
        }
        .buttonStyle(.plain)
        .help("Cancel")
        .accessibilityLabel("Cancel generation")
        .accessibilityIdentifier("cancel-generation")
    }

    // MARK: - Chrome

    private var barBackground: Color {
        PremiumStyle.fieldFill
    }

    private var barStroke: Color {
        PremiumStyle.cardStroke
    }

    private var sendBackground: Color {
        if canSend {
            // Ready: a pour of house copper in both schemes
            return PremiumStyle.brand
        }
        // Idle: soft warm-gray circle
        return colorScheme == .dark
            ? Color(red: 0.42, green: 0.38, blue: 0.34)
            : Color(red: 0.28, green: 0.20, blue: 0.11).opacity(0.14)
    }

    private var sendForeground: Color {
        if canSend {
            return colorScheme == .dark ? Color.black.opacity(0.88) : Color.white
        }
        return colorScheme == .dark
            ? Color.white.opacity(0.42)
            : Color.primary.opacity(0.35)
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
                    .font(.system(size: compact ? 13 : 14, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(hovering ? 0.72 : 0.48))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(hovering ? 0.55 : 0.35))
            }
            .padding(.horizontal, compact ? PremiumStyle.space8 : PremiumStyle.space12)
            .padding(.vertical, compact ? PremiumStyle.rowInsetV : PremiumStyle.space8)
            .background(
                hovering
                    ? Color.primary.opacity(0.07)
                    : Color.clear,
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
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                    }
                }
                if let description = model.description, !description.isEmpty {
                    Text(description)
                        .font(.caption)
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

/// Backward-compatible alias used by older call sites.
typealias ChatComposerProviderLabel = ModelSelector
