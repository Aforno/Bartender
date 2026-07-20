import AppKit
import Combine
import Foundation
import UniformTypeIdentifiers
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    let store = AppletStore()
    let providers = AIProviderService()
    let preferences = AppPreferences()
    let launchAtLogin = LaunchAtLoginController()
    let updates = UpdateService()
    let shellApprovals: ShellApprovalStore
    let generatedTools: GeneratedToolArtifactStore
    let runtime: AppletRuntimeEngine

    /// Compatibility for views still referencing `codex`.
    var codex: AIProviderService { providers }

    @Published var selection: UUID? {
        didSet {
            if oldValue != selection, generation?.phase.isActive != true {
                composerText = ""
            }
        }
    }
    @Published var composerText = ""
    @Published var generation: GenerationSession?
    @Published var bannerMessage: String?
    @Published var showingProviderSetup = false
    /// Mirrored for scene invalidation (dynamic status item count).
    @Published private(set) var enabledApplets: [AppletManifest] = []

    private var cancellables = Set<AnyCancellable>()

    var selectedApplet: AppletManifest? {
        store.applet(id: selection)
    }

    init() {
        let approvals = ShellApprovalStore()
        let artifacts = GeneratedToolArtifactStore()
        shellApprovals = approvals
        generatedTools = artifacts
        runtime = AppletRuntimeEngine(shellApprovals: approvals, generatedTools: artifacts)

        store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
                DispatchQueue.main.async {
                    self?.refreshEnabledApplets()
                }
            }
            .store(in: &cancellables)

        runtime.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        providers.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        preferences.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        refreshEnabledApplets()
    }

    func bootstrap() async {
        AppLog.app.info("Bar Tender bootstrap")
        await providers.refreshAvailability()
        runtime.sync(with: store.applets)
        refreshEnabledApplets()
        if selection == nil {
            selection = store.applets.first?.id
        }
        if let loadIssue = store.loadIssue {
            bannerMessage = loadIssue
        }
    }

    func clearLibrary() {
        do {
            try store.removeAll()
            shellApprovals.removeAll()
            do {
                try generatedTools.removeAll()
            } catch {
                AppLog.store.error("Could not remove generated tool artifacts: \(error.localizedDescription, privacy: .public)")
            }
            runtime.stopAll()
            runtime.sync(with: store.applets)
            selection = nil
            bannerMessage = "Library cleared."
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    private func refreshEnabledApplets() {
        enabledApplets = store.enabledApplets
    }

    func refreshCodex() async {
        await providers.refreshAvailability()
    }

    func refreshProviders() async {
        await providers.refreshAvailability()
    }

    func beginNewTool() {
        guard generation?.phase.isActive != true else { return }
        selection = nil
        composerText = ""
        generation = nil
        bannerMessage = nil
    }

    /// Revises the selected tool in place, or creates one when the New Tool page is active.
    func createFromPrompt(_ prompt: String? = nil) async {
        await generateTool(from: prompt, replacing: selectedApplet)
    }

    /// Creates a tool without inheriting the main window's current library selection.
    func createNewToolFromPrompt(_ prompt: String? = nil) async {
        await generateTool(from: prompt, replacing: nil)
    }

    private func generateTool(
        from prompt: String?,
        replacing existingTool: AppletManifest?
    ) async {
        let resolved = (prompt ?? composerText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !resolved.isEmpty else {
            bannerMessage = existingTool == nil
                ? "Describe a new menu bar tool to build."
                : "Describe the change you want to make to “\(existingTool?.name ?? "this tool")”."
            return
        }
        guard providers.availability.isReady else {
            if providers.anyProviderReady {
                bannerMessage = "\(providers.selectedProvider.displayName) is not ready. Pick another provider."
            } else {
                bannerMessage = "No AI provider CLI is ready."
            }
            return
        }
        guard generation?.phase.isActive != true else { return }

        composerText = resolved

        let provider = providers.selectedProvider
        let session = GenerationSession(
            prompt: resolved,
            provider: provider,
            targetAppletID: existingTool?.id,
            targetAppletName: existingTool?.name
        )
        generation = session
        session.phase = .preparing
        if let existingTool {
            session.append(stream: .system, "Revising “\(existingTool.name)” with \(provider.displayName)…")
        } else {
            session.append(stream: .system, "Starting a new tool with \(provider.displayName)…")
        }
        AppLog.menuBar.info("\(existingTool == nil ? "Create" : "Revise") from prompt via \(provider.rawValue, privacy: .public) (\(resolved.count, privacy: .public) chars)")

        do {
            session.phase = .running
            let manifest = try await providers.generateManifest(
                prompt: resolved,
                existingTool: existingTool,
                provider: provider
            ) { stream, text in
                session.append(stream: stream, text)
            }
            let candidate = ManifestGenerationSupport.replacing(
                manifest,
                existingTool: existingTool
            )
            session.phase = .parsing
            session.append(stream: .system, "Validating the generated tool…")
            if candidate.kind == .generatedTool {
                session.append(stream: .system, "Checking zsh syntax and basic policy rules…")
                try await GeneratedToolSourceValidator.validate(candidate)
            }
            if candidate.kind == .shellCommand {
                let env = await ShellEnvironment.loginEnvironment()
                try ManifestGenerationSupport.requireCommandAvailable(candidate, environment: env)
            }
            let saved = try store.upsert(candidate)
            if existingTool != nil {
                shellApprovals.revoke(id: saved.id)
            }
            if saved.kind == .generatedTool {
                let executable = try generatedTools.install(saved)
                session.append(stream: .system, "Installed executable at \(executable.path)")
            }
            runtime.restart(manifest: saved)
            runtime.sync(with: store.applets)
            selection = saved.id
            session.resultManifest = saved
            session.phase = .succeeded
            session.finishedAt = .now
            session.append(
                stream: .system,
                existingTool == nil
                    ? "Installed “\(saved.name)” in the menu bar."
                    : "Updated “\(saved.name)” in place."
            )
            composerText = ""
            if existingTool != nil {
                bannerMessage = "Updated “\(saved.name)” in place. Review the revised code to run it."
            } else {
                bannerMessage = saved.kind == .generatedTool
                    ? "Generated “\(saved.name)”. Review its code once, then allow it to run."
                    : "Created “\(saved.name)” with \(provider.displayName)."
            }
            AppLog.app.info("Created applet \(saved.name, privacy: .public) via \(provider.rawValue, privacy: .public)")
        } catch is CancellationError {
            session.phase = .cancelled
            session.finishedAt = .now
            session.append(stream: .system, "Cancelled.")
        } catch let error as ProviderGenerationError {
            switch error {
            case .cancelled:
                session.phase = .cancelled
            default:
                session.phase = .failed
            }
            session.errorMessage = error.localizedDescription
            session.finishedAt = .now
            session.append(stream: .system, error.localizedDescription)
            bannerMessage = error.localizedDescription
        } catch {
            session.phase = .failed
            session.errorMessage = error.localizedDescription
            session.finishedAt = .now
            session.append(stream: .system, error.localizedDescription)
            bannerMessage = error.localizedDescription
        }
    }

    func cancelGeneration() {
        providers.cancelGeneration()
        generation?.phase = .cancelled
        generation?.finishedAt = .now
        generation?.append(stream: .system, "Cancellation requested…")
    }

    func deleteSelected() {
        guard let id = selection, let applet = store.applet(id: id) else { return }

        if preferences.confirmBeforeDelete {
            let alert = NSAlert()
            alert.messageText = "Delete “\(applet.name)”?"
            alert.informativeText = "This removes the applet from your library. This cannot be undone."
            alert.alertStyle = .warning
            alert.addButton(withTitle: "Delete")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }

        do {
            try store.delete(id: id)
            shellApprovals.revoke(id: id)
            do {
                try generatedTools.remove(id: id)
            } catch {
                AppLog.store.error("Could not remove generated tool artifact: \(error.localizedDescription, privacy: .public)")
            }
            runtime.stop(id: id)
            runtime.sync(with: store.applets)
            selection = store.applets.first?.id
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    func saveEdits(_ manifest: AppletManifest) {
        do {
            let saved = try store.upsert(manifest)
            if saved.kind == .generatedTool {
                _ = try generatedTools.install(saved)
            }
            runtime.restart(manifest: saved)
            runtime.sync(with: store.applets)
            bannerMessage = "Saved “\(saved.name)”."
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    func toggleEnabled(_ manifest: AppletManifest) {
        setEnabled(manifest, enabled: !manifest.enabled)
    }

    func setEnabled(_ manifest: AppletManifest, enabled: Bool) {
        do {
            guard let updated = try store.setEnabled(id: manifest.id, enabled: enabled) else { return }
            runtime.restart(manifest: updated)
            runtime.sync(with: store.applets)
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    func setFailureNotifications(_ enabled: Bool, for manifest: AppletManifest) {
        setNotifications(enabled, for: manifest, keyPath: \.notifyOnFailure)
    }

    func setCompletionNotifications(_ enabled: Bool, for manifest: AppletManifest) {
        setNotifications(enabled, for: manifest, keyPath: \.notifyOnComplete)
    }

    private func setNotifications(
        _ enabled: Bool,
        for manifest: AppletManifest,
        keyPath: WritableKeyPath<AppletManifest, Bool>
    ) {
        Task {
            if enabled, !(await ensureNotificationPermission()) { return }
            do {
                try store.update(manifest.id) { updated in
                    updated[keyPath: keyPath] = enabled
                }
                if let updated = store.applet(id: manifest.id) {
                    runtime.restart(manifest: updated)
                }
            } catch {
                bannerMessage = error.localizedDescription
            }
        }
    }

    func isShellApproved(_ manifest: AppletManifest) -> Bool {
        shellApprovals.isApproved(manifest)
    }

    func isExecutionApproved(_ manifest: AppletManifest) -> Bool {
        shellApprovals.isApproved(manifest)
    }

    func setShellApproval(_ approved: Bool, for manifest: AppletManifest) {
        setExecutionApproval(approved, for: manifest)
    }

    func setExecutionApproval(_ approved: Bool, for manifest: AppletManifest) {
        shellApprovals.setApproved(approved, for: manifest)
        if let persisted = store.applet(id: manifest.id) {
            runtime.restart(manifest: persisted)
        }
        objectWillChange.send()
    }

    func addSampleLibrary() {
        do {
            for sample in AppletManifest.samples {
                if !store.applets.contains(where: { $0.name == sample.name && $0.kind == sample.kind }) {
                    try store.upsert(sample)
                }
            }
            runtime.sync(with: store.applets)
            selection = store.applets.first?.id
            bannerMessage = "Sample applets added to the library."
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    func exportLibrary() {
        let panel = NSSavePanel()
        panel.title = "Export Bar Tender Library"
        panel.nameFieldStringValue = "BarTender-Library.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try store.exportArchiveData().write(to: url, options: [.atomic])
            bannerMessage = "Exported \(store.applets.count) tool(s)."
        } catch {
            bannerMessage = "Could not export the library: \(error.localizedDescription)"
        }
    }

    func importLibrary() {
        let panel = NSOpenPanel()
        panel.title = "Import Bar Tender Library"
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }

        let choice = NSAlert()
        choice.messageText = "Import this tool library?"
        choice.informativeText = "Merge keeps your current tools. Replace removes the current library first. Imported generated code always requires fresh approval."
        choice.addButton(withTitle: "Merge")
        choice.addButton(withTitle: "Replace All")
        choice.addButton(withTitle: "Cancel")
        let response = choice.runModal()
        guard response != .alertThirdButtonReturn else { return }
        let mode: AppletImportMode = response == .alertSecondButtonReturn ? .replace : .merge

        do {
            let data = try Data(contentsOf: url)
            let imported = try store.importArchiveData(data, mode: mode)
            if mode == .replace {
                shellApprovals.removeAll()
                try? generatedTools.removeAll()
            }
            for manifest in imported {
                shellApprovals.revoke(id: manifest.id)
                if manifest.kind == .generatedTool {
                    _ = try generatedTools.install(manifest)
                } else {
                    try? generatedTools.remove(id: manifest.id)
                }
            }
            runtime.sync(with: store.applets)
            refreshEnabledApplets()
            selection = imported.first?.id ?? store.applets.first?.id
            bannerMessage = "Imported \(imported.count) tool(s). Review generated source before running it."
        } catch {
            bannerMessage = "Could not import the library: \(error.localizedDescription)"
        }
    }

    func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.title = "Export Sanitized Diagnostics"
        panel.nameFieldStringValue = "BarTender-Diagnostics.txt"
        panel.allowedContentTypes = [.plainText]
        guard panel.runModal() == .OK, let url = panel.url else { return }

        do {
            try diagnosticsReport().write(to: url, atomically: true, encoding: .utf8)
            bannerMessage = "Exported sanitized diagnostics. Prompts, source, paths, credentials, and tool output were excluded."
        } catch {
            bannerMessage = "Could not export diagnostics: \(error.localizedDescription)"
        }
    }

    func diagnosticsReport() -> String {
        let info = Bundle.main.infoDictionary
        let version = info?["CFBundleShortVersionString"] as? String ?? "Development"
        let build = info?["CFBundleVersion"] as? String ?? "local"
        let providerLines = AIProvider.allCases.map { provider in
            "- \(provider.displayName): \(sanitizedProviderStatus(provider))"
        }.joined(separator: "\n")

        return """
        Bar Tender sanitized diagnostics
        Generated: \(Date().formatted(.iso8601))
        App: \(version) (\(build))
        Bundle: \(Bundle.main.bundleIdentifier ?? "development")
        macOS: \(ProcessInfo.processInfo.operatingSystemVersionString)
        Architecture: \(Self.architectureName)
        Tools: \(store.applets.count) total, \(store.enabledApplets.count) enabled
        Launch at login: \(launchAtLogin.isEnabled ? "enabled" : "disabled")
        Providers:
        \(providerLines)

        Privacy: this report excludes prompts, generated source, executable paths,
        working directories, authentication details, credentials, logs, and tool output.
        """
    }

    private func sanitizedProviderStatus(_ provider: AIProvider) -> String {
        switch providers.status(for: provider) {
        case .checking:
            return "checking"
        case .ready(let installation):
            return "ready (\(installation.version))"
        case .unavailable(let issue):
            switch issue {
            case .notFound: return "CLI not found"
            case .notAuthenticated: return "not authenticated"
            case .versionCheckFailed: return "version check failed"
            case .loginCheckFailed: return "login check failed"
            }
        }
    }

    private static var architectureName: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }

    func requestNotificationPermission() {
        Task { _ = await ensureNotificationPermission() }
    }

    private func ensureNotificationPermission() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            AppLog.app.info("Notifications granted=\(granted, privacy: .public)")
            if !granted {
                bannerMessage = "Notifications are off. You can enable Bar Tender in System Settings."
            }
            return granted
        } catch {
            AppLog.app.error("Notification auth error: \(error.localizedDescription, privacy: .public)")
            bannerMessage = "Could not enable notifications: \(error.localizedDescription)"
            return false
        }
    }
}
