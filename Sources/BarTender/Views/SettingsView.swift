import AppKit
import SwiftUI

/// macOS Settings window: Providers and App (General) panes.
struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var providers: AIProviderService
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        TabView {
            ProviderSettingsPane()
                .tabItem {
                    Label("Providers", systemImage: "terminal")
                }
                .tag(SettingsTab.providers)

            AppSettingsPane()
                .tabItem {
                    Label("General", systemImage: "gearshape")
                }
                .tag(SettingsTab.general)
        }
        .frame(width: 520, height: 420)
    }
}

private enum SettingsTab: Hashable {
    case providers
    case general
}

// MARK: - Providers

private struct ProviderSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var providers: AIProviderService
    @State private var isRechecking = false

    var body: some View {
        Form {
            Section {
                ForEach(AIProvider.allCases) { provider in
                    Toggle(isOn: binding(for: provider)) {
                        HStack(spacing: 10) {
                            Image(systemName: provider.systemImage)
                                .foregroundStyle(.secondary)
                                .frame(width: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName)
                                Text(statusLine(for: provider))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                }
            } header: {
                Text("Model providers")
            } footer: {
                Text("Turn providers on or off. Only enabled providers appear in the message bar model selector. At least one must stay on.")
            }

            Section {
                Button {
                    Task {
                        isRechecking = true
                        await model.refreshProviders()
                        isRechecking = false
                    }
                } label: {
                    HStack {
                        Text("Recheck providers")
                        Spacer()
                        if isRechecking {
                            ProgressView()
                                .controlSize(.small)
                        }
                    }
                }
                .disabled(isRechecking)
            } footer: {
                Text("Checks install path, version, and login for each CLI.")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
    }

    private func binding(for provider: AIProvider) -> Binding<Bool> {
        Binding(
            get: { providers.isProviderEnabled(provider) },
            set: { providers.setProviderEnabled(provider, enabled: $0) }
        )
    }

    private func statusLine(for provider: AIProvider) -> String {
        if !providers.isProviderEnabled(provider) {
            return "Off"
        }
        switch providers.status(for: provider) {
        case .checking:
            return "Checking…"
        case .ready(let install):
            return "Ready · \(install.version)"
        case .unavailable(let issue):
            return issue.title(for: provider)
        }
    }
}

// MARK: - App / General

private struct AppSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: AppletStore
    @EnvironmentObject private var preferences: AppPreferences
    @State private var confirmClearLibrary = false

    var body: some View {
        Form {
            Section {
                Toggle("Show inspector on launch", isOn: $preferences.showInspectorOnLaunch)
                Toggle("Show model selector in composer", isOn: $preferences.showProviderInComposer)
                Toggle("Confirm before deleting tools", isOn: $preferences.confirmBeforeDelete)
            } header: {
                Text("Interface")
            } footer: {
                Text("Inspector preference applies the next time you open Bar Tender. Composer controls update immediately.")
            }

            Section {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Generation timeout")
                        Spacer()
                        Text("\(Int(preferences.generationTimeoutSeconds))s")
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Slider(
                        value: $preferences.generationTimeoutSeconds,
                        in: 30...600,
                        step: 15
                    )
                }
            } header: {
                Text("Generation")
            } footer: {
                Text("How long Bar Tender waits for the local CLI (Codex, Claude, or Grok) before cancelling.")
            }

            Section {
                LabeledContent("Tools in library", value: "\(store.applets.count)")
                LabeledContent("Enabled", value: "\(store.enabledApplets.count)")

                Button("Add built-in samples") {
                    model.addSampleLibrary()
                }

                Button("Reveal library in Finder") {
                    revealLibrary()
                }

                Button("Clear library…", role: .destructive) {
                    confirmClearLibrary = true
                }
                .disabled(store.applets.isEmpty)
            } header: {
                Text("Library")
            } footer: {
                Text(preferences.libraryFileURL.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .textSelection(.enabled)
            }

            Section {
                Button("Open Notification Settings…") {
                    openNotificationSettings()
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Tool completion and failure alerts use macOS notifications when enabled for Bar Tender.")
            }

            Section {
                LabeledContent("App", value: "Bar Tender")
                LabeledContent("Version", value: appVersion)
                LabeledContent("Integration", value: "Local CLIs · Process")
                Text("Each prompt produces a dedicated local executable. Generated source is shown for review and requires source-bound approval before it runs.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .alert("Clear library?", isPresented: $confirmClearLibrary) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) {
                model.clearLibrary()
            }
        } message: {
            Text("This permanently removes all \(store.applets.count) tool(s), approvals, and generated artifacts from Bar Tender. This cannot be undone.")
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private func revealLibrary() {
        let url = store.storageURL
        let dir = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(dir)
        }
    }

    private func openNotificationSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.Notifications-Settings.extension") {
            NSWorkspace.shared.open(url)
        } else if let url = URL(string: "x-apple.systempreferences:com.apple.preference.notifications") {
            NSWorkspace.shared.open(url)
        }
    }
}
