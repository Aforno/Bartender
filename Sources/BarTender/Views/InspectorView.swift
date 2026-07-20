import SwiftUI

struct InspectorView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: AppletStore
    @EnvironmentObject private var runtime: AppletRuntimeEngine

    @State private var draft: AppletManifest?
    @State private var showGeneratedSource = false

    var body: some View {
        Group {
            if let applet = model.selectedApplet {
                Form {
                    Section("Identity") {
                        TextField("Name", text: binding(for: applet, \.name))
                        TextField("SF Symbol", text: binding(for: applet, \.iconSystemName))
                        LabeledContent("Kind", value: applet.kind.displayName)
                        TextField("Title template", text: binding(for: applet, \.titleTemplate))
                    }

                    Section("Behavior") {
                        Toggle("Enabled", isOn: binding(for: applet, \.enabled))
                        if applet.kind != .timer && applet.kind != .countdown {
                            TextField(
                                "Refresh seconds",
                                value: Binding(
                                    get: {
                                        current(applet).refreshIntervalSeconds ?? applet.kind.defaultRefreshInterval ?? 10
                                    },
                                    set: { newValue in
                                        update(applet) { $0.refreshIntervalSeconds = newValue }
                                    }
                                ),
                                format: .number
                            )
                        }
                        Toggle("Notify on complete", isOn: binding(for: applet, \.notifyOnComplete))
                        Toggle("Notify on failure", isOn: binding(for: applet, \.notifyOnFailure))
                    }

                    configSection(for: applet)

                    Section("Live state") {
                        if let snap = runtime.snapshots[applet.id] {
                            LabeledContent("Title", value: snap.title)
                            LabeledContent("Status", value: snap.statusText)
                            LabeledContent("Healthy", value: snap.isHealthy ? "Yes" : "No")
                            LabeledContent("Updated", value: snap.updatedAt.formatted(date: .omitted, time: .standard))
                        } else {
                            Text("No runtime snapshot yet.")
                                .foregroundStyle(.secondary)
                        }
                    }

                    Section {
                        Button {
                            let value = current(applet)
                            model.saveEdits(value)
                            draft = nil
                        } label: {
                            Label("Apply & Restart", systemImage: "checkmark.circle.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .keyboardShortcut(.return, modifiers: [.command])

                        Button(role: .destructive) {
                            model.deleteSelected()
                            draft = nil
                        } label: {
                            Label("Delete Tool", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                    }
                }
                .formStyle(.grouped)
                .onChange(of: model.selection) { _, _ in
                    draft = nil
                    showGeneratedSource = false
                }
            } else {
                ContentUnavailableView(
                    "No Selection",
                    systemImage: "sidebar.trailing",
                    description: Text("Select a tool to edit its settings.")
                )
            }
        }
    }

    @ViewBuilder
    private func configSection(for applet: AppletManifest) -> some View {
        switch applet.kind {
        case .generatedTool:
            Section("Generated Code") {
                DisclosureGroup(isExpanded: $showGeneratedSource) {
                    TextEditor(text: configString(applet, keyPath: \.generatedSource))
                        .font(.system(.caption, design: .monospaced))
                        .frame(minHeight: 220)
                        .accessibilityLabel("Generated tool source")
                        .padding(.top, 6)
                } label: {
                    HStack {
                        Label("View or edit source", systemImage: "chevron.left.forwardslash.chevron.right")
                        Spacer()
                        Text("\(generatedSourceLineCount(applet)) lines")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }
                TextField("Working directory (optional)", text: configString(applet, keyPath: \.workingDirectory))
                TextField(
                    "Run timeout (seconds)",
                    value: configBinding(applet, keyPath: \.timeoutSeconds, default: 15),
                    format: .number
                )
            }

            Section("Permission") {
                Toggle(
                    "Allow this generated tool to run",
                    isOn: Binding(
                        get: { model.isExecutionApproved(current(applet)) },
                        set: { newValue in
                            model.setExecutionApproval(newValue, for: current(applet))
                        }
                    )
                )
                Text("Expand the source above to review it. Approval is tied to this exact code and working directory; any edit revokes it automatically.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

        case .timer, .countdown:
            Section("Timer") {
                TextField(
                    "Duration (seconds)",
                    value: configBinding(applet, keyPath: \.durationSeconds, default: 1500),
                    format: .number
                )
                Toggle(
                    "Auto restart",
                    isOn: Binding(
                        get: { current(applet).config.autoRestart ?? false },
                        set: { newValue in
                            update(applet) { $0.config.autoRestart = newValue }
                        }
                    )
                )
            }

        case .httpMonitor:
            Section("HTTP Monitor") {
                TextField("URL", text: configString(applet, keyPath: \.url))
                TextField(
                    "Expected status (optional)",
                    value: Binding(
                        get: { current(applet).config.expectedStatusCode ?? 0 },
                        set: { newValue in
                            update(applet) {
                                $0.config.expectedStatusCode = newValue == 0 ? nil : newValue
                            }
                        }
                    ),
                    format: .number
                )
                TextField(
                    "Timeout seconds",
                    value: configBinding(applet, keyPath: \.timeoutSeconds, default: 5),
                    format: .number
                )
            }

        case .portMonitor:
            Section("Port Monitor") {
                TextField("Host", text: configString(applet, keyPath: \.host))
                TextField(
                    "Port",
                    value: configBinding(applet, keyPath: \.port, default: 3000),
                    format: .number
                )
                TextField(
                    "Timeout seconds",
                    value: configBinding(applet, keyPath: \.timeoutSeconds, default: 2),
                    format: .number
                )
            }

        case .systemMetrics:
            Section("Metrics") {
                Toggle("CPU", isOn: metricBinding(applet, .cpu))
                Toggle("Memory", isOn: metricBinding(applet, .memory))
            }

        case .gitStatus:
            Section("Git") {
                TextField("Repository path", text: configString(applet, keyPath: \.repositoryPath))
            }

        case .shellCommand:
            Section("Shell Command") {
                TextField("Command", text: configString(applet, keyPath: \.command), axis: .vertical)
                    .lineLimit(2...5)
                TextField("Working directory", text: configString(applet, keyPath: \.workingDirectory))
                Toggle(
                    "I approve running this command",
                    isOn: Binding(
                        get: { model.isExecutionApproved(current(applet)) },
                        set: { newValue in
                            model.setExecutionApproval(newValue, for: current(applet))
                        }
                    )
                )
                Text("Approval is tied to this exact command and working directory. Editing either requires approval again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Draft helpers

    private func current(_ applet: AppletManifest) -> AppletManifest {
        draft ?? applet
    }

    private func generatedSourceLineCount(_ applet: AppletManifest) -> Int {
        max(1, current(applet).config.generatedSource?.split(whereSeparator: \.isNewline).count ?? 0)
    }

    private func update(_ applet: AppletManifest, _ body: (inout AppletManifest) -> Void) {
        var value = current(applet)
        body(&value)
        draft = value
    }

    private func binding(for applet: AppletManifest, _ keyPath: WritableKeyPath<AppletManifest, String>) -> Binding<String> {
        Binding(
            get: { current(applet)[keyPath: keyPath] },
            set: { newValue in update(applet) { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func binding(for applet: AppletManifest, _ keyPath: WritableKeyPath<AppletManifest, Bool>) -> Binding<Bool> {
        Binding(
            get: { current(applet)[keyPath: keyPath] },
            set: { newValue in update(applet) { $0[keyPath: keyPath] = newValue } }
        )
    }

    private func configString(
        _ applet: AppletManifest,
        keyPath: WritableKeyPath<AppletConfig, String?>
    ) -> Binding<String> {
        Binding(
            get: { current(applet).config[keyPath: keyPath] ?? "" },
            set: { newValue in
                update(applet) {
                    $0.config[keyPath: keyPath] = newValue.isEmpty ? nil : newValue
                }
            }
        )
    }

    private func configBinding<T>(
        _ applet: AppletManifest,
        keyPath: WritableKeyPath<AppletConfig, T?>,
        default defaultValue: T
    ) -> Binding<T> {
        Binding(
            get: { current(applet).config[keyPath: keyPath] ?? defaultValue },
            set: { newValue in
                update(applet) { $0.config[keyPath: keyPath] = newValue }
            }
        )
    }

    private func metricBinding(_ applet: AppletManifest, _ metric: SystemMetricKind) -> Binding<Bool> {
        Binding(
            get: {
                (current(applet).config.metrics ?? []).contains(metric)
            },
            set: { enabled in
                update(applet) { manifest in
                    var metrics = Set(manifest.config.metrics ?? [])
                    if enabled {
                        metrics.insert(metric)
                    } else {
                        metrics.remove(metric)
                    }
                    manifest.config.metrics = SystemMetricKind.allCases.filter { metrics.contains($0) }
                }
            }
        )
    }
}
