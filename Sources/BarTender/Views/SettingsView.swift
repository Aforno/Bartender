import AppKit
import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase
    @State private var selection = SettingsTab.general

    var body: some View {
        VStack(spacing: 0) {
            SettingsTabSelector(selection: $selection)
            BarTenderHairline()
            selectedPane
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 560, idealWidth: 600, minHeight: 500, idealHeight: 560)
        .foregroundStyle(PremiumStyle.primaryText)
        .deepBlackWindowSurface()
        .overlay(alignment: .top) {
            if let banner = model.bannerMessage {
                BannerView(text: banner) { model.bannerMessage = nil }
                    .padding(.top, 48)
            }
        }
        .onAppear { model.launchAtLogin.refresh() }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { model.launchAtLogin.refresh() }
        }
    }

    @ViewBuilder
    private var selectedPane: some View {
        switch selection {
        case .general: GeneralSettingsPane()
        case .providers: ProviderSettingsPane()
        case .library: LibrarySettingsPane()
        case .support: SupportSettingsPane()
        }
    }
}

private enum SettingsTab: String, CaseIterable, Identifiable {
    case general
    case providers
    case library
    case support

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: "General"
        case .providers: "Providers"
        case .library: "Library"
        case .support: "Support"
        }
    }

    var symbol: String {
        switch self {
        case .general: "gearshape"
        case .providers: "sparkles"
        case .library: "books.vertical"
        case .support: "questionmark.circle"
        }
    }
}

private struct SettingsTabSelector: View {
    @Binding var selection: SettingsTab

    var body: some View {
        HStack(spacing: 4) {
            ForEach(SettingsTab.allCases) { tab in
                Button {
                    selection = tab
                } label: {
                    Label(tab.title, systemImage: tab.symbol)
                        .font(BarTenderFont.control)
                        .foregroundStyle(Color.white.opacity(selection == tab ? 0.92 : 0.50))
                        .padding(.horizontal, 10)
                        .frame(height: 26)
                        .background(
                            selection == tab ? PremiumStyle.raisedStrong : .clear,
                            in: RoundedRectangle(cornerRadius: PremiumStyle.controlRadius, style: .continuous)
                        )
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(selection == tab ? .isSelected : [])
            }
            Spacer()
        }
        .padding(.horizontal, PremiumStyle.contentMargin)
        .padding(.vertical, 10)
        .background(PremiumStyle.canvas)
    }
}

// MARK: - General

private struct GeneralSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var preferences: AppPreferences

    var body: some View {
        SettingsScroll {
            SettingsHeading(
                title: "General",
                detail: "Control Bar Tender's interface, menu bar tools, startup, and updates."
            )

            SettingsSection(title: "Interface") {
                SettingsToggleRow(
                    title: "Show model selector",
                    detail: "Keep the active model visible in the composer.",
                    isOn: $preferences.showProviderInComposer
                )
                SettingsToggleRow(
                    title: "Confirm before deleting tools",
                    detail: "Ask before removing a tool from the local library.",
                    isOn: $preferences.confirmBeforeDelete
                )
            }

            SettingsSection(title: "Menu Bar") {
                SettingsControlRow(
                    title: "Visible tools",
                    detail: "Limit individual menu bar items; every tool remains in the manager menu."
                ) {
                    HStack(spacing: 8) {
                        Text("\(preferences.maximumMenuBarItems)")
                            .font(BarTenderFont.control.monospacedDigit())
                            .foregroundStyle(PremiumStyle.secondaryText)
                            .frame(minWidth: 18)
                        Stepper(
                            "Visible tools",
                            value: $preferences.maximumMenuBarItems,
                            in: 1...AppPreferences.maximumMenuBarItemsBound
                        )
                        .labelsHidden()
                        .controlSize(.small)
                        .accessibilityIdentifier("maximum-menu-bar-items")
                    }
                }
            }

            SettingsSection(title: "Generated Tools") {
                SettingsToggleRow(
                    title: "Automatically approve safe revisions",
                    detail: "Only previously approved, same-identity provider edits qualify. New tools and repairs still require review.",
                    isOn: $preferences.autoApproveGeneratedToolEdits
                )
                .accessibilityIdentifier("auto-approve-generated-tool-edits")
            }

            SettingsSection(title: "Notifications") {
                SettingsControlRow(
                    title: "Tool alerts",
                    detail: "Use macOS notifications for completion and failure alerts."
                ) {
                    HStack(spacing: 8) {
                        Button("Enable") { model.requestNotificationPermission() }
                            .buttonStyle(BarTenderPillButtonStyle())
                        Button("Open Settings") { openNotificationSettings() }
                            .buttonStyle(BarTenderPillButtonStyle())
                    }
                }
            }

            SettingsSection(title: "Startup") {
                LaunchAtLoginSetting(controller: model.launchAtLogin)
            }

            SettingsSection(title: "Updates") {
                UpdateSetting(service: model.updates)
            }
        }
    }

    private func openNotificationSettings() {
        let modern = "x-apple.systempreferences:com.apple.Notifications-Settings.extension"
        let fallback = "x-apple.systempreferences:com.apple.preference.notifications"
        if let url = URL(string: modern) ?? URL(string: fallback) {
            NSWorkspace.shared.open(url)
        }
    }
}

// MARK: - Providers

private struct ProviderSettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var providers: AIProviderService
    @State private var isRechecking = false

    var body: some View {
        SettingsScroll {
            SettingsHeading(
                title: "Providers",
                detail: "Choose which local model CLIs Bar Tender can use to build and revise tools."
            )

            SettingsSection(title: "Model Providers") {
                ForEach(AIProvider.allCases) { provider in
                    SettingsControlRow {
                        HStack(spacing: 10) {
                            ProviderIcon(provider: provider, size: 20)
                                .frame(width: 24, height: 24)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(provider.displayName)
                                    .font(.system(size: 13, weight: .medium))
                                    .foregroundStyle(Color.white.opacity(0.90))
                                Text(statusLine(for: provider))
                                    .font(BarTenderFont.caption)
                                    .foregroundStyle(PremiumStyle.secondaryText)
                                    .lineLimit(1)
                            }
                        }
                    } control: {
                        Toggle(provider.displayName, isOn: binding(for: provider))
                            .labelsHidden()
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .accessibilityIdentifier("provider-toggle.\(provider.rawValue)")
                    }
                }
            }

            SettingsSection(title: "Provider Tools") {
                SettingsControlRow(
                    title: "Installation and login",
                    detail: "Open guided setup or recheck each CLI's path, version, and account."
                ) {
                    HStack(spacing: 8) {
                        Button("Setup") {
                            model.showingProviderSetup = true
                            AppActions.shared.openMainWindow()
                        }
                        .buttonStyle(BarTenderPillButtonStyle())

                        Button(isRechecking ? "Checking…" : "Recheck") {
                            Task {
                                isRechecking = true
                                await model.refreshProviders()
                                isRechecking = false
                            }
                        }
                        .buttonStyle(BarTenderPillButtonStyle())
                        .disabled(isRechecking)
                    }
                }
            }
        }
    }

    private func binding(for provider: AIProvider) -> Binding<Bool> {
        Binding(
            get: { providers.isProviderEnabled(provider) },
            set: { enabled in
                if !enabled, providers.enabledProviders.count == 1 {
                    model.bannerMessage = "At least one model provider must stay enabled."
                    return
                }
                providers.setProviderEnabled(provider, enabled: enabled)
            }
        )
    }

    private func statusLine(for provider: AIProvider) -> String {
        if !providers.isProviderEnabled(provider) { return "Off" }
        return switch providers.status(for: provider) {
        case .checking: "Checking…"
        case .ready(let install): "Ready · \(install.version)"
        case .unavailable(let issue): issue.title(for: provider)
        }
    }
}

// MARK: - Library

private struct LibrarySettingsPane: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var store: AppletStore
    @EnvironmentObject private var preferences: AppPreferences
    @State private var confirmClearLibrary = false

    var body: some View {
        SettingsScroll {
            SettingsHeading(
                title: "Library",
                detail: "Inspect, transfer, or reset the local collection of menu bar tools."
            )

            SettingsSection(title: "Overview") {
                SettingsValueRow(title: "Tools", value: "\(store.applets.count)")
                SettingsValueRow(title: "Enabled", value: "\(store.enabledApplets.count)")
            }

            SettingsSection(title: "Local Library") {
                SettingsControlRow(
                    title: "Library file",
                    detail: preferences.libraryFileURL.path
                ) {
                    HStack(spacing: 8) {
                        Button("Add Samples") { model.addSampleLibrary() }
                            .buttonStyle(BarTenderPillButtonStyle())
                        Button("Reveal") { revealLibrary() }
                            .buttonStyle(BarTenderPillButtonStyle())
                    }
                }
            }

            SettingsSection(title: "Transfer") {
                SettingsControlRow(
                    title: "Import or export",
                    detail: "Move the validated library manifest between Macs."
                ) {
                    HStack(spacing: 8) {
                        Button("Export") { model.exportLibrary() }
                            .buttonStyle(BarTenderPillButtonStyle())
                            .disabled(store.applets.isEmpty)
                        Button("Import") { model.importLibrary() }
                            .buttonStyle(BarTenderPillButtonStyle())
                    }
                }
            }

            SettingsSection(title: "Danger Zone") {
                SettingsControlRow(
                    title: "Clear local library",
                    detail: "Remove every tool, approval, and generated artifact."
                ) {
                    Button("Clear Library", role: .destructive) { confirmClearLibrary = true }
                        .buttonStyle(BarTenderPillButtonStyle(destructive: true))
                        .disabled(store.applets.isEmpty)
                }
            }
        }
        .alert("Clear library?", isPresented: $confirmClearLibrary) {
            Button("Cancel", role: .cancel) {}
            Button("Clear All", role: .destructive) { model.clearLibrary() }
        } message: {
            Text("This permanently removes all \(store.applets.count) tool(s), approvals, and generated artifacts from Bar Tender. This cannot be undone.")
        }
    }

    private func revealLibrary() {
        let url = store.storageURL
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        if FileManager.default.fileExists(atPath: url.path) {
            NSWorkspace.shared.activateFileViewerSelecting([url])
        } else {
            NSWorkspace.shared.open(directory)
        }
    }
}

// MARK: - Support

private struct SupportSettingsPane: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        SettingsScroll {
            SettingsHeading(
                title: "Support",
                detail: "Get help, export private-by-default diagnostics, and inspect app information."
            )

            SettingsSection(title: "Help") {
                SettingsControlRow(
                    title: "Troubleshooting",
                    detail: "Open the issue tracker or export sanitized local diagnostics."
                ) {
                    HStack(spacing: 8) {
                        Button("Open Issues") { openURL("https://github.com/Aforno/Bartender/issues") }
                            .buttonStyle(BarTenderPillButtonStyle())
                        Button("Export Diagnostics") { model.exportDiagnostics() }
                            .buttonStyle(BarTenderPillButtonStyle())
                    }
                }
            }

            SettingsSection(title: "Privacy") {
                SettingsControlRow(
                    title: "Privacy information",
                    detail: "Diagnostics exclude prompts, generated source, paths, credentials, and tool output."
                ) {
                    Button("Read Privacy") {
                        openURL("https://github.com/Aforno/Bartender/blob/main/PRIVACY.md")
                    }
                    .buttonStyle(BarTenderPillButtonStyle())
                }
            }

            SettingsSection(title: "About") {
                SettingsValueRow(title: "App", value: "Bar Tender")
                SettingsValueRow(title: "Version", value: appVersion)
                SettingsValueRow(title: "Integration", value: "Local CLIs · Process")
                GeneratedCodeTrustDisclosure(compact: true)
                    .padding(.vertical, 8)
            }
        }
    }

    private var appVersion: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "Development"
        let build = info?["CFBundleVersion"] as? String ?? "local"
        return "\(short) (\(build))"
    }

    private func openURL(_ value: String) {
        guard let url = URL(string: value) else { return }
        NSWorkspace.shared.open(url)
    }
}

// MARK: - Shared settings components

private struct SettingsScroll<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 28) {
                content
            }
            .padding(.horizontal, PremiumStyle.contentMargin)
            .padding(.top, PremiumStyle.contentMargin)
            .padding(.bottom, PremiumStyle.space32)
        }
        .background(PremiumStyle.canvas)
    }
}

private struct SettingsHeading: View {
    let title: String
    let detail: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(BarTenderFont.display)
                .foregroundStyle(PremiumStyle.primaryText)
            Text(detail)
                .font(BarTenderFont.caption)
                .foregroundStyle(PremiumStyle.secondaryText)
        }
    }
}

private struct SettingsSection<Content: View>: View {
    let title: String
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title)
                .font(BarTenderFont.sectionLabel)
                .foregroundStyle(Color.white.opacity(0.74))
                .padding(.bottom, 8)
            content
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct SettingsControlRow<Label: View, Control: View>: View {
    @ViewBuilder let label: Label
    @ViewBuilder let control: Control

    init(
        @ViewBuilder label: () -> Label,
        @ViewBuilder control: () -> Control
    ) {
        self.label = label()
        self.control = control()
    }

    var body: some View {
        HStack(alignment: .center, spacing: 16) {
            label
                .frame(maxWidth: .infinity, alignment: .leading)
            control.layoutPriority(1)
        }
        .padding(.vertical, 9)
    }
}

private extension SettingsControlRow where Label == SettingsRowLabel {
    init(
        title: String,
        detail: String? = nil,
        @ViewBuilder control: () -> Control
    ) {
        self.init {
            SettingsRowLabel(title: title, detail: detail)
        } control: {
            control()
        }
    }
}

private struct SettingsRowLabel: View {
    let title: String
    let detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(title)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.white.opacity(0.90))
            if let detail {
                Text(detail)
                    .font(BarTenderFont.caption)
                    .foregroundStyle(PremiumStyle.secondaryText)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
            }
        }
    }
}

private struct SettingsToggleRow: View {
    let title: String
    let detail: String?
    @Binding var isOn: Bool

    var body: some View {
        SettingsControlRow(title: title, detail: detail) {
            Toggle(title, isOn: $isOn)
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
        }
    }
}

private struct SettingsValueRow: View {
    let title: String
    let value: String

    var body: some View {
        SettingsControlRow(title: title) {
            Text(value)
                .font(BarTenderFont.control)
                .foregroundStyle(PremiumStyle.secondaryText)
                .textSelection(.enabled)
        }
    }
}

private struct LaunchAtLoginSetting: View {
    @ObservedObject var controller: LaunchAtLoginController

    var body: some View {
        SettingsControlRow(
            title: "Launch at login",
            detail: controller.statusMessage ?? "Start Bar Tender and its enabled tools when you sign in."
        ) {
            Toggle("Launch Bar Tender at login", isOn: Binding(
                get: { controller.isEnabled },
                set: { controller.setEnabled($0) }
            ))
            .labelsHidden()
            .toggleStyle(.switch)
            .controlSize(.small)
            .accessibilityIdentifier("launch-at-login")
        }
    }
}

private struct UpdateSetting: View {
    @ObservedObject var service: UpdateService

    var body: some View {
        SettingsControlRow(
            title: "App updates",
            detail: service.statusText ?? "Check the project's GitHub Releases page on demand."
        ) {
            HStack(spacing: 8) {
                Button(service.state == .checking ? "Checking…" : "Check") {
                    Task { await service.check() }
                }
                .buttonStyle(BarTenderPillButtonStyle())
                .disabled(service.state == .checking)
                .accessibilityIdentifier("check-for-updates")

                if let url = service.availableReleaseURL {
                    Button("Download") { NSWorkspace.shared.open(url) }
                        .buttonStyle(BarTenderPillButtonStyle())
                }
            }
        }
    }
}
