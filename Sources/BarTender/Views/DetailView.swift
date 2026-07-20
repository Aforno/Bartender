import SwiftUI

/// Each tool is presented as a Notion-style document: title, property rows,
/// then the menu bar preview, review request and build receipt as plain page content.
struct DetailView: View {
    @EnvironmentObject private var model: AppModel
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
            .padding(.horizontal, 48)
            .padding(.top, 34)
            .padding(.bottom, 30)
        }
        .background(Color.clear)
    }

    // MARK: - Page

    @ViewBuilder
    private func page(for applet: AppletManifest) -> some View {
        header(applet)
        props(applet)

        Divider()
            .padding(.vertical, 18)

        if applet.kind == .timer || applet.kind == .countdown {
            timerControls(applet)
        }

        pageSection("Menu bar")
        MenuBarPreviewView(
            manifest: applet,
            snapshot: runtime.snapshots[applet.id] ?? .placeholder(for: applet)
        )

        if applet.kind == .generatedTool, !model.isExecutionApproved(applet) {
            pageSection("Review")
            reviewCallout(applet)
        }

        pageSection("Build")
        if let generation = model.generation,
           generation.phase.isActive || generation.resultManifest?.id == applet.id {
            CodexLogView(session: generation)
        } else {
            savedBuildReceipt(applet)
        }
    }

    private func pageSection(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 16, weight: .semibold))
            .padding(.top, 22)
            .padding(.bottom, 10)
    }

    // MARK: - Header

    private func header(_ applet: AppletManifest) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Image(systemName: applet.iconSystemName)
                .symbolRenderingMode(.hierarchical)
                .font(.system(size: 32))
                .foregroundStyle(.primary)
                .frame(height: 40)

            Text(applet.name)
                .font(.system(size: 28, weight: .bold))
        }
        .padding(.bottom, 14)
    }

    // MARK: - Property rows

    private func props(_ applet: AppletManifest) -> some View {
        let runState = ToolRunState.resolve(
            manifest: applet,
            snapshot: runtime.snapshots[applet.id],
            executionApproved: model.isExecutionApproved(applet)
        )
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
            }
        }
    }

    private func tint(for state: ToolRunState) -> Color {
        switch state {
        case .running: return .green
        case .reviewRequired, .needsAttention: return .orange
        case .disabled, .idle: return .secondary
        }
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
        HStack(spacing: 9) {
            Button {
                runtime.toggleTimer(id: applet.id, manifest: applet)
            } label: {
                Label(
                    runtime.snapshots[applet.id]?.isRunning == true ? "Pause" : "Start",
                    systemImage: runtime.snapshots[applet.id]?.isRunning == true ? "pause.fill" : "play.fill"
                )
            }
            Button {
                runtime.resetTimer(id: applet.id, manifest: applet)
            } label: {
                Label("Reset", systemImage: "arrow.counterclockwise")
            }
            if applet.notifyOnComplete {
                Text("Notification fires on completion")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .padding(.leading, 4)
            }
        }
        .controlSize(.small)
        .padding(.bottom, 2)
    }

    // MARK: - Review callout

    private func reviewCallout(_ applet: AppletManifest) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "lock.fill")
                    .font(.callout)
                    .foregroundStyle(.orange)
                    .frame(width: 16)

                VStack(alignment: .leading, spacing: 2) {
                    Text("Read the source, then allow it once")
                        .font(.callout.weight(.semibold))
                    Text("Bar Tender generated a dedicated executable for this request. Approval binds to this exact code and working directory — any edit revokes it automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            ZStack(alignment: .topTrailing) {
                ScrollView(.vertical) {
                    Text(applet.config.generatedSource ?? "")
                        .font(.system(size: 11, design: .monospaced))
                        .lineSpacing(3)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(12)
                }
                .frame(maxHeight: 200)
                .background(
                    Color.primary.opacity(0.05),
                    in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                )

                Text("zsh")
                    .font(.system(size: 10.5))
                    .foregroundStyle(.tertiary)
                    .padding(.top, 8)
                    .padding(.trailing, 12)
            }

            HStack(spacing: 6) {
                Label("\(sourceLineCount(applet)) lines · any edit revokes approval", systemImage: "checkmark.shield")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    model.showInspector = true
                } label: {
                    Text("Open in Inspector")
                }
                Button {
                    model.setExecutionApproval(true, for: applet)
                } label: {
                    Label("Allow & Run", systemImage: "play.fill")
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(14)
        .background(
            PremiumStyle.surfaceFill,
            in: RoundedRectangle(cornerRadius: 8, style: .continuous)
        )
    }

    private func sourceLineCount(_ applet: AppletManifest) -> Int {
        max(1, applet.config.generatedSource?.split(whereSeparator: \.isNewline).count ?? 0)
    }

    // MARK: - Saved build receipt

    private func savedBuildReceipt(_ applet: AppletManifest) -> some View {
        HStack(spacing: 7) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
            Text(applet.kind == .generatedTool ? "Source installed" : "Built-in tool saved")
                .font(.callout.weight(.medium))
                .foregroundStyle(.green)
            Text("· \(applet.createdAt.formatted(date: .abbreviated, time: .shortened)) · \(refreshLabel(applet).lowercased()) · source-bound approval")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 20) {
            ContentUnavailableView {
                Label {
                    Text("Create your first menu bar tool")
                } icon: {
                    Image(systemName: "wineglass")
                        .font(.system(size: 44, weight: .light))
                }
            } description: {
                Text("Describe what you want to see or control. Bar Tender uses your local AI CLI to write a dedicated tool, installs it as a menu bar item, and shows you the code before it can run.")
            }

            HStack(spacing: 10) {
                Button {
                    model.composerText = "Show the song currently playing in Music, or say Not Playing."
                } label: {
                    Label("Try an Idea", systemImage: "wand.and.stars")
                }
                .buttonStyle(.borderedProminent)

                Button {
                    model.addSampleLibrary()
                } label: {
                    Text("Explore built-in samples")
                }
            }
            .controlSize(.large)
        }
        .frame(maxWidth: .infinity, minHeight: 420)
        .padding(.top, 32)
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

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Label(label, systemImage: systemImage)
                .font(.system(size: 12.5))
                .foregroundStyle(.tertiary)
                .frame(width: 148, alignment: .leading)

            content()
                .font(.system(size: 13))

            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            Color.primary.opacity(hovering ? 0.045 : 0),
            in: RoundedRectangle(cornerRadius: 6, style: .continuous)
        )
        .padding(.horizontal, -8)
        .onHover { hovering = $0 }
        .animation(.snappy(duration: 0.12), value: hovering)
    }
}
