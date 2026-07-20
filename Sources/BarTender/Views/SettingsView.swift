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
        .frame(minWidth: 480, idealWidth: 560, minHeight: 500, idealHeight: 640)
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
                            ProviderIcon(provider: provider, size: 18)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(provider.displayName)
                                Text(statusLine(for: provider))
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                        }
                    }
                    .accessibilityIdentifier("provider-toggle.\(provider.rawValue)")
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
        .padding(.vertical, PremiumStyle.space8)
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
                Toggle("Show model selector in composer", isOn: $preferences.showProviderInComposer)
                Toggle("Confirm before deleting tools", isOn: $preferences.confirmBeforeDelete)
            } header: {
                Text("Interface")
            } footer: {
                Text("Composer controls update immediately.")
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

                Button("Export Library…") {
                    model.exportLibrary()
                }
                .disabled(store.applets.isEmpty)

                Button("Import Library…") {
                    model.importLibrary()
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
                Button("Enable Notifications…") {
                    model.requestNotificationPermission()
                }
                Button("Open Notification Settings…") {
                    openNotificationSettings()
                }
            } header: {
                Text("Notifications")
            } footer: {
                Text("Tool completion and failure alerts use macOS notifications when enabled for Bar Tender.")
            }

            Section {
                LaunchAtLoginSetting(controller: model.launchAtLogin)
                Text("Closing the window keeps Bar Tender and its tools running. Quitting Bar Tender stops every tool until the app starts again.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } header: {
                Text("Lifecycle")
            }

            Section {
                UpdateSetting(service: model.updates)
            } header: {
                Text("Updates")
            } footer: {
                Text("Updates are checked only when you ask. Downloads come from the signed GitHub Releases page.")
            }

            Section {
                Button("Provider Setup…") {
                    model.showingProviderSetup = true
                    NSApp.activate(ignoringOtherApps: true)
                    NSApp.windows.first(where: \.canBecomeKey)?.makeKeyAndOrderFront(nil)
                }
                Button("Export Sanitized Diagnostics…") {
                    model.exportDiagnostics()
                }
                Button("Support and Troubleshooting…") {
                    openURL("https://github.com/Aforno/Bartender/issues")
                }
                Button("Privacy Information…") {
                    openURL("https://github.com/Aforno/Bartender/blob/main/PRIVACY.md")
                }
            } header: {
                Text("Support")
            } footer: {
                Text("Diagnostics exclude prompts, generated source, paths, credentials, provider output, and tool output.")
            }

            Section {
                LabeledContent("App", value: "Bar Tender")
                LabeledContent("Version", value: appVersion)
                LabeledContent("Integration", value: "Local CLIs · Process")
                GeneratedCodeTrustDisclosure(compact: true)
            } header: {
                Text("About")
            }
        }
        .formStyle(.grouped)
        .padding(.vertical, PremiumStyle.space8)
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
        let short = info?["CFBundleShortVersionString"] as? String ?? "Development"
        let build = info?["CFBundleVersion"] as? String ?? "local"
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

    private func openURL(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
}

private struct LaunchAtLoginSetting: View {
    @ObservedObject var controller: LaunchAtLoginController

    var body: some View {
        Toggle("Launch Bar Tender at login", isOn: Binding(
            get: { controller.isEnabled },
            set: { controller.setEnabled($0) }
        ))
        .accessibilityIdentifier("launch-at-login")

        if let message = controller.statusMessage {
            Text(message)
                .font(.caption)
                .foregroundStyle(.orange)
        }
    }
}

private struct UpdateSetting: View {
    @ObservedObject var service: UpdateService

    var body: some View {
        Button(service.state == .checking ? "Checking…" : "Check for Updates…") {
            Task { await service.check() }
        }
        .disabled(service.state == .checking)
        .accessibilityIdentifier("check-for-updates")

        if let status = service.statusText {
            Text(status)
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        if let url = service.availableReleaseURL {
            Button("Open Download Page…") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
