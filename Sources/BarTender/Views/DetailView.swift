import SwiftUI

/// Each tool is presented as a Notion-style document: title, property rows,
/// then the menu bar preview, review request and build receipt as plain page content.
struct DetailView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: AppletStore
    @EnvironmentObject private var runtime: AppletRuntimeEngine

    var body: some View {
        ScrollView {
            HStack {
                Spacer(minLength: 0)
                VStack(alignment: .leading, spacing: 0) {
                    if let applet = model.selectedApplet {
                        page(for: applet)
                    } else {
                        emptyState
                    }
                }
                .frame(maxWidth: 680, alignment: .leading)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, PremiumStyle.contentMargin)
            .padding(.top, PremiumStyle.space32)
            .padding(.bottom, PremiumStyle.space32)
        }
        .background(PremiumStyle.canvas)
    }

    // MARK: - Page

    @ViewBuilder
    private func page(for applet: AppletManifest) -> some View {
        header(applet)
        props(applet)

        Divider()
            .padding(.vertical, PremiumStyle.space16)

        if applet.kind == .timer || applet.kind == .countdown {
            timerControls(applet)
        }

        pageSection("Menu bar preview")
        MenuBarPreviewView(
            manifest: applet,
            snapshot: runtime.snapshots[applet.id] ?? .placeholder(for: applet),
            runState: runState(for: applet)
        )

        if applet.kind == .generatedTool, !model.isExecutionApproved(applet) {
            pageSection(model.isValidatingExecution(applet) ? "Testing" : "Review")
            reviewCallout(applet)
        }

        if applet.kind == .shellCommand {
            pageSection(model.isShellApproved(applet) ? "Command approval" : "Review")
            shellCommandApprovalCallout(applet)
        }

        pageSection("Build")
        if let generation = generationSession(for: applet) {
            CodexLogView(session: generation)
        } else {
            savedBuildReceipt(applet)
        }
    }

    private func pageSection(_ title: String) -> some View {
        Text(title)
            .font(.inter(size: 17, weight: .semibold))
            .accessibilityAddTraits(.isHeader)
            .padding(.top, PremiumStyle.space24)
            .padding(.bottom, PremiumStyle.space8)
    }

    // MARK: - Header

    private func header(_ applet: AppletManifest) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: applet.iconSystemName)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 32))
                .foregroundStyle(PremiumStyle.brand)
                .frame(height: 40)

            Text(applet.name)
                .font(.inter(size: 30, weight: .bold))
                .accessibilityAddTraits(.isHeader)
        }
        .padding(.bottom, PremiumStyle.space16)
    }

    // MARK: - Property rows

    private func props(_ applet: AppletManifest) -> some View {
        let runState = runState(for: applet)
        return VStack(alignment: .leading, spacing: 1) {
            PropertyRow(label: "Kind", systemImage: "tag") {
                Text(applet.kind.displayName + (applet.kind == .generatedTool ? " · zsh" : ""))
            }

            PropertyRow(label: "State", systemImage: "clock") {
                HStack(spacing: 7) {
                    Circle()
                        .fill(tint(for: runState))
                        .frame(width: 7, height: 7)
                    Text(runState.title)
                        .foregroundStyle(tint(for: runState))
                }
            }

            PropertyRow(label: "Refresh", systemImage: "arrow.clockwise") {
                Text(refreshLabel(applet))
            }

            PropertyRow(label: "Created", systemImage: "calendar") {
                Text(applet.createdAt.formatted(date: .abbreviated, time: .shortened))
            }

            if !applet.sourcePrompt.isEmpty {
                PropertyRow(label: "Prompt", systemImage: "text.quote") {
                    Text(applet.sourcePrompt)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            PropertyRow(label: "Enabled", systemImage: "checkmark") {
                Toggle("", isOn: Binding(
                    get: { applet.enabled },
                    set: { newValue in model.setEnabled(applet, enabled: newValue) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Enable \(applet.name)")
                .accessibilityIdentifier("tool-enabled.\(applet.id.uuidString)")
            }

            PropertyRow(label: "Failure alerts", systemImage: "exclamationmark.bubble") {
                Toggle("", isOn: Binding(
                    get: { applet.notifyOnFailure },
                    set: { model.setFailureNotifications($0, for: applet) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
                .accessibilityLabel("Notify when \(applet.name) fails")
            }

            if applet.kind == .timer || applet.kind == .countdown {
                PropertyRow(label: "Completion alerts", systemImage: "bell") {
                    Toggle("", isOn: Binding(
                        get: { applet.notifyOnComplete },
                        set: { model.setCompletionNotifications($0, for: applet) }
                    ))
                    .labelsHidden()
                    .toggleStyle(.switch)
                    .controlSize(.small)
                    .accessibilityLabel("Notify when \(applet.name) completes")
                }
            }
        }
    }

    private func tint(for state: ToolRunState) -> Color {
        switch state {
        case .running: return .green
        case .validating: return PremiumStyle.brand
        case .reviewRequired, .needsAttention: return .orange
        case .disabled, .idle: return .secondary
        }
    }

    private func runState(for applet: AppletManifest) -> ToolRunState {
        ToolRunState.resolve(
            manifest: applet,
            snapshot: runtime.snapshots[applet.id],
            executionApproved: model.isExecutionApproved(applet),
            isValidating: model.isValidatingExecution(applet)
        )
    }

    private func refreshLabel(_ applet: AppletManifest) -> String {
        guard let interval = applet.refreshIntervalSeconds ?? applet.kind.defaultRefreshInterval else {
            return "Event driven"
        }
        let seconds = Int(interval)
        return seconds == 1 ? "Every second" : "Every \(seconds) seconds"
    }

    // MARK: - Timer controls

    private func timerControls(_ applet: AppletManifest) -> some View {
        let isRunning = applet.enabled && runtime.snapshots[applet.id]?.isRunning == true
        return HStack(spacing: 9) {
            Button {
                runtime.toggleTimer(id: applet.id, manifest: applet)
            } label: {
                Label(
                    isRunning ? "Pause" : "Start",
                    systemImage: isRunning ? "pause.fill" : "play.fill"
                )
            }
            .disabled(!applet.enabled)

            Button {
                runtime.resetTimer(id: applet.id, manifest: applet)
            } label: {
                Label("Restart", systemImage: "arrow.counterclockwise")
            }
            .disabled(!applet.enabled)
            .help("Restart at the full duration")

            if !applet.enabled {
                Text("Enable this tool to use timer controls")
                    .font(.inter(.caption))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, PremiumStyle.space4)
            } else if applet.notifyOnComplete {
                Text("Notification fires on completion")
                    .font(.inter(.caption))
                    .foregroundStyle(.tertiary)
                    .padding(.leading, PremiumStyle.space4)
            }
        }
        .controlSize(.small)
        .padding(.bottom, PremiumStyle.space2)
    }

    // MARK: - Review callout

    private func reviewCallout(_ applet: AppletManifest) -> some View {
        let isValidating = model.isValidatingExecution(applet)
        return VStack(alignment: .leading, spacing: PremiumStyle.space12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: isValidating ? "hourglass" : "lock.fill")
                    .font(.callout)
                    .foregroundStyle(isValidating ? PremiumStyle.brand : Color.orange)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(isValidating ? "Testing this exact source" : "Read the source, then allow and test it")
                        .font(.inter(.callout, weight: .semibold))
                    Text(
                        isValidating
                            ? "Bar Tender is running the first-run check. Approval becomes active only after this exact code returns a healthy result."
                            : "Approval binds to this exact code and working directory. The first run is tested, and failures go back to your selected provider for repair; changed code requires review again."
                    )
                        .font(.inter(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            GeneratedCodeTrustDisclosure(compact: true)

            ZStack(alignment: .topTrailing) {
                ScrollView(.vertical) {
                    Text(applet.config.generatedSource ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(PremiumStyle.space12)
                }
                .frame(maxHeight: 200)
                .background(
                    PremiumStyle.fieldFill,
                    in: RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous)
                        .strokeBorder(PremiumStyle.cardStroke, lineWidth: 1)
                )

                Text("zsh")
                    .font(.inter(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, PremiumStyle.space8)
                    .padding(.trailing, PremiumStyle.space12)
            }

            HStack(spacing: 6) {
                Label("\(sourceLineCount(applet)) lines · any edit revokes approval", systemImage: "checkmark.shield")
                    .font(.inter(.caption))
                    .foregroundStyle(.secondary)
                Spacer()
                if isValidating {
                    HStack(spacing: 7) {
                        ProgressView()
                            .controlSize(.small)
                        Text("Testing…")
                            .font(.inter(.callout, weight: .medium))
                    }
                    .accessibilityElement(children: .combine)
                    .accessibilityLabel("Testing generated source")
                } else {
                    Button {
                        model.setExecutionApproval(true, for: applet)
                    } label: {
                        Label("Allow, Test & Run", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("allow-and-run.\(applet.id.uuidString)")
                }
            }
        }
        .padding(PremiumStyle.space16)
        .borderedContainer(cornerRadius: PremiumStyle.cardRadius)
    }

    private func sourceLineCount(_ applet: AppletManifest) -> Int {
        max(1, applet.config.generatedSource?.split(whereSeparator: \.isNewline).count ?? 0)
    }

    // MARK: - Shell command approval

    private func shellCommandApprovalCallout(_ applet: AppletManifest) -> some View {
        let approved = model.isShellApproved(applet)
        let command = applet.config.command ?? "No command configured"
        let workingDirectory = applet.config.workingDirectory
            ?? "Not set — inherits Bar Tender’s process directory"

        return VStack(alignment: .leading, spacing: PremiumStyle.space12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: approved ? "checkmark.shield.fill" : "lock.fill")
                    .font(.callout)
                    .foregroundStyle(approved ? Color.green : Color.orange)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text(approved ? "This exact command is approved" : "Review this command before it runs")
                        .font(.inter(.callout, weight: .semibold))
                    Text("Approval is bound to the exact command and working directory below. Any edit revokes approval.")
                        .font(.inter(.caption))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            shellCommandValue(label: "Command", value: command, accessibilityLabel: "Shell command")
            shellCommandValue(
                label: "Working directory",
                value: workingDirectory,
                accessibilityLabel: "Shell command working directory"
            )

            Text("Approved commands run through your login shell with your user privileges and can read or change files, use the network, and launch commands or apps.")
                .font(.inter(.caption))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack {
                Label(
                    approved ? "Approval current" : "Approval required",
                    systemImage: approved ? "checkmark.circle" : "exclamationmark.triangle"
                )
                .font(.inter(.caption))
                .foregroundStyle(approved ? Color.green : Color.orange)

                Spacer()

                if approved {
                    Button("Revoke Approval", role: .destructive) {
                        model.setShellApproval(false, for: applet)
                    }
                    .accessibilityIdentifier("revoke-shell-command.\(applet.id.uuidString)")
                } else {
                    Button {
                        model.setShellApproval(true, for: applet)
                    } label: {
                        Label(applet.enabled ? "Allow & Run" : "Allow Command", systemImage: "play.fill")
                    }
                    .buttonStyle(.borderedProminent)
                    .accessibilityIdentifier("allow-shell-command.\(applet.id.uuidString)")
                }
            }
        }
        .padding(PremiumStyle.space16)
        .borderedContainer(cornerRadius: PremiumStyle.cardRadius)
    }

    private func shellCommandValue(
        label: String,
        value: String,
        accessibilityLabel: String
    ) -> some View {
        VStack(alignment: .leading, spacing: PremiumStyle.space4) {
            Text(label)
                .font(.inter(.caption, weight: .semibold))
                .foregroundStyle(.secondary)

            ScrollView(.horizontal) {
                Text(value)
                    .font(.system(size: 11, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: true, vertical: false)
                    .padding(PremiumStyle.space12)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                PremiumStyle.fieldFill,
                in: RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous)
            )
            .overlay(
                RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous)
                    .strokeBorder(PremiumStyle.cardStroke, lineWidth: 1)
            )
            .accessibilityLabel(accessibilityLabel)
            .accessibilityValue(value)
        }
    }

    // MARK: - Saved build receipt

    private func generationSession(for applet: AppletManifest) -> GenerationSession? {
        guard let generation = model.generation else { return nil }
        if generation.targetAppletID == applet.id {
            return generation
        }
        if generation.targetAppletID == nil, generation.resultManifest?.id == applet.id {
            return generation
        }
        return nil
    }

    private func savedBuildReceipt(_ applet: AppletManifest) -> some View {
        let approvalBound = applet.kind == .generatedTool || applet.kind == .shellCommand
        let isValidating = model.isValidatingExecution(applet)
        let requiresReview = approvalBound && !model.isExecutionApproved(applet)
        let tint: Color = isValidating ? PremiumStyle.brand : (requiresReview ? .orange : .green)
        let approvalLabel: String? = if approvalBound {
            isValidating ? "first-run check in progress" : (requiresReview ? "review required" : "approval current")
        } else {
            nil
        }
        let metadata = [
            applet.createdAt.formatted(date: .abbreviated, time: .shortened),
            refreshLabel(applet).lowercased(),
            approvalLabel,
        ]
        .compactMap { $0 }
        .joined(separator: " · ")

        return HStack(spacing: 7) {
            Image(
                systemName: isValidating
                    ? "hourglass"
                    : (requiresReview ? "exclamationmark.circle.fill" : "checkmark.circle.fill")
            )
                .foregroundStyle(tint)
            Text(isValidating ? "Testing source" : savedReceiptTitle(for: applet))
                .font(.inter(.callout, weight: .medium))
                .foregroundStyle(tint)
            Text("· \(metadata)")
                .font(.inter(.caption))
                .foregroundStyle(.tertiary)
        }
    }

    private func savedReceiptTitle(for applet: AppletManifest) -> String {
        switch applet.kind {
        case .generatedTool:
            return "Source installed"
        case .shellCommand:
            return "Command saved"
        default:
            return "Built-in tool saved"
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            ContentUnavailableView {
                Label {
                    Text(store.applets.isEmpty ? "Create your first menu bar tool" : "Create a new menu bar tool")
                        .accessibilityAddTraits(.isHeader)
                } icon: {
                    Image(systemName: "wineglass")
                        .font(.system(size: 44, weight: .light))
                        .foregroundStyle(PremiumStyle.brand)
                }
            } description: {
                Text("Describe what you want to see or control. Bar Tender writes the tool—you review the code before it runs.")
            }

            HStack(spacing: 10) {
                Button {
                    model.composerText = "Show the song currently playing in Music, or say Not Playing."
                } label: {
                    Label("Try an Idea", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)

                if hasMissingSamples {
                    Button {
                        model.addSampleLibrary()
                    } label: {
                        Text("Add built-in samples")
                    }
                }
            }
            .controlSize(.large)
            .disabled(model.generation?.phase.isActive == true)

            if let generation = newToolGenerationSession {
                VStack(alignment: .leading, spacing: PremiumStyle.space8) {
                    Text("Build")
                        .font(.inter(size: 17, weight: .semibold))
                        .accessibilityAddTraits(.isHeader)
                    CodexLogView(session: generation)
                }
                .frame(maxWidth: 680, alignment: .leading)
            }
        }
        .frame(maxWidth: .infinity, minHeight: 420)
        .padding(.top, PremiumStyle.space32)
    }

    private var newToolGenerationSession: GenerationSession? {
        guard let generation = model.generation, generation.targetAppletID == nil else {
            return nil
        }
        return generation
    }

    private var hasMissingSamples: Bool {
        AppletManifest.samples.contains { sample in
            !store.applets.contains { $0.name == sample.name && $0.kind == sample.kind }
        }
    }
}

// MARK: - Property row

/// Notion-style label/value row with a hover wash. Read-only values;
/// interactive values (like the Enabled switch) handle themselves.
private struct PropertyRow<Content: View>: View {
    let label: String
    let systemImage: String
    @ViewBuilder var content: () -> Content

    @State private var hovering = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(label, systemImage: systemImage)
                .font(.inter(size: 12.5))
                .foregroundStyle(.tertiary)
                .frame(width: 148, alignment: .leading)

            content()
                .font(.inter(size: 13))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, PremiumStyle.rowInsetH)
        .padding(.vertical, PremiumStyle.space4)
        .background(
            Color.primary.opacity(hovering ? 0.045 : 0),
            in: RoundedRectangle(cornerRadius: PremiumStyle.chipRadius, style: .continuous)
        )
        .padding(.horizontal, -PremiumStyle.rowInsetH)
        .onHover { hovering = $0 }
        .animation(reduceMotion ? nil : .snappy(duration: 0.12), value: hovering)
    }
}
