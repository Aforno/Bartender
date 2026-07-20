import SwiftUI

/// Shared message input used by the main window and menu bar panel.
/// Rounded-rectangle field — a SaaS-style input, not a floating pill.
struct ChatComposerBar<Accessory: View>: View {
    @Binding var text: String
    var placeholder: String = "Message Bar Tender"
    var canSend: Bool
    var isBusy: Bool = false
    var lineLimit: ClosedRange<Int> = 1...6
    var submitHelp: String = "Generate tool (⌘↩)"
    var onSend: () -> Void
    var onPlus: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    @ViewBuilder var accessory: () -> Accessory

    @Environment(\.colorScheme) private var colorScheme
    @FocusState private var focused: Bool

    /// Target single-line height (controls + vertical padding).
    private let controlSize: CGFloat = 32
    private let barRadius: CGFloat = 12

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            plusButton

            TextField(placeholder, text: $text, axis: .vertical)
                .textFieldStyle(.plain)
                .font(.system(size: 15))
                .foregroundStyle(.primary)
                .lineLimit(lineLimit)
                .focused($focused)
                .disabled(isBusy)
                .frame(minHeight: controlSize, alignment: .center)
                .onSubmit(onSend)

            accessory()
                .fixedSize()

            if isBusy, let onCancel {
                cancelButton(onCancel)
            } else {
                sendButton
            }
        }
        .padding(.leading, 14)
        .padding(.trailing, 10)
        .padding(.vertical, 10)
        .frame(minHeight: 52)
        .background(barBackground, in: RoundedRectangle(cornerRadius: barRadius, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: barRadius, style: .continuous)
                .strokeBorder(barStroke, lineWidth: 1)
        )
    }

    // MARK: - Controls

    private var plusButton: some View {
        Button {
            onPlus?()
            focused = true
        } label: {
            Image(systemName: "plus")
                .font(.system(size: 17, weight: .regular))
                .foregroundStyle(Color.primary.opacity(0.50))
                .frame(width: controlSize, height: controlSize)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .disabled(isBusy)
        .help("Start with a suggestion")
    }

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
        .animation(.snappy(duration: 0.15), value: canSend)
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
    }

    // MARK: - Chrome

    private var barBackground: Color {
        colorScheme == .dark
            ? Color(red: 0.188, green: 0.188, blue: 0.188)
            : Color(nsColor: .textBackgroundColor)
    }

    private var barStroke: Color {
        colorScheme == .dark
            ? Color.white.opacity(0.08)
            : Color.black.opacity(0.09)
    }

    private var sendBackground: Color {
        if canSend {
            // Ready: solid light circle (dark mode) / solid dark (light mode)
            return colorScheme == .dark ? Color(red: 0.92, green: 0.92, blue: 0.92) : Color.primary
        }
        // Idle: soft mid-gray pill like ChatGPT's disabled send
        return colorScheme == .dark
            ? Color(red: 0.40, green: 0.40, blue: 0.40)
            : Color.primary.opacity(0.14)
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

    var body: some View {
        Menu {
            let models = providers.selectableModels
            if models.isEmpty {
                Text("No models available")
            } else {
                ForEach(groupedProviders(from: models), id: \.self) { provider in
                    Section(provider.displayName) {
                        ForEach(models.filter { $0.provider == provider }) { model in
                            Button {
                                providers.selectModel(model)
                            } label: {
                                modelRow(model)
                            }
                        }
                    }
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(providers.selectedModel.shortLabel)
                    .font(.system(size: compact ? 13 : 14, weight: .medium))
                    .foregroundStyle(Color.primary.opacity(hovering ? 0.72 : 0.48))
                    .lineLimit(1)

                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(Color.primary.opacity(hovering ? 0.55 : 0.35))
            }
            .padding(.horizontal, compact ? 8 : 10)
            .padding(.vertical, compact ? 5 : 6)
            .background(
                hovering
                    ? Color.primary.opacity(0.07)
                    : Color.clear,
                in: RoundedRectangle(cornerRadius: 6, style: .continuous)
            )
            .contentShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .disabled(isBusy)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.12), value: hovering)
        .help("Choose model")
        .accessibilityLabel("Model")
        .accessibilityValue(providers.selectedModel.displayName)
    }

    @ViewBuilder
    private func modelRow(_ model: AIModelOption) -> some View {
        let selected = providers.selectedModel.id == model.id
        HStack(alignment: .firstTextBaseline, spacing: 8) {
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
