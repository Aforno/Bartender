import AppKit
import Combine
import Foundation
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    let store = AppletStore()
    let providers = AIProviderService()
    let preferences = AppPreferences()
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
    @Published var showInspector: Bool
    @Published var composerText = ""
    @Published var generation: GenerationSession?
    @Published var bannerMessage: String?
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
        showInspector = true

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

        showInspector = preferences.showInspectorOnLaunch
        refreshEnabledApplets()
    }

    func bootstrap() async {
        AppLog.app.info("Bar Tender bootstrap")
        requestNotificationPermission()
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
                provider: provider,
                timeout: preferences.generationTimeout
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
                session.append(stream: .system, "Checking zsh syntax and unattended execution requirements…")
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
            case .timedOut:
                session.phase = .timedOut
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

    private func requestNotificationPermission() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { granted, error in
            if let error {
                AppLog.app.error("Notification auth error: \(error.localizedDescription, privacy: .public)")
            } else {
                AppLog.app.info("Notifications granted=\(granted, privacy: .public)")
            }
        }
    }
}
