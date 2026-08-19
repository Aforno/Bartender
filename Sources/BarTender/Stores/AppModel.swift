import Combine
import Foundation
import UserNotifications

@MainActor
final class AppModel: ObservableObject {
    private struct PersistedManifest {
        var manifest: AppletManifest
        var executable: URL?
    }

    let store: AppletStore
    let providers: AIProviderService
    let preferences: AppPreferences
    let launchAtLogin: LaunchAtLoginController
    let updates: UpdateService
    let shellApprovals: ShellApprovalStore
    let generatedTools: GeneratedToolArtifactStore
    let runtime: AppletRuntimeEngine

    @Published var selection: UUID? {
        didSet {
            if oldValue != selection, generation?.phase.isActive != true {
                composerText = ""
            }
        }
    }
    @Published var composerText = ""
    @Published var generation: GenerationSession? {
        didSet {
            observeGenerationSession()
        }
    }
    @Published var bannerMessage: String?
    @Published var showingProviderSetup = false

    private var cancellables = Set<AnyCancellable>()
    private var generationCancellable: AnyCancellable?
    private var bootstrapTask: Task<Void, Never>?
    private var validationTasks: [UUID: Task<Void, Never>] = [:]
    private var validationTokens: [UUID: UUID] = [:]

    var selectedApplet: AppletManifest? {
        store.applet(id: selection)
    }

    init(
        store: AppletStore? = nil,
        providers: AIProviderService? = nil,
        preferences: AppPreferences? = nil,
        launchAtLogin: LaunchAtLoginController? = nil,
        updates: UpdateService? = nil,
        shellApprovals: ShellApprovalStore? = nil,
        generatedTools: GeneratedToolArtifactStore? = nil,
        runtime: AppletRuntimeEngine? = nil
    ) {
        let resolvedApprovals = shellApprovals ?? ShellApprovalStore()
        let resolvedArtifacts = generatedTools ?? GeneratedToolArtifactStore()
        self.store = store ?? AppletStore()
        self.providers = providers ?? AIProviderService()
        self.preferences = preferences ?? AppPreferences()
        self.launchAtLogin = launchAtLogin ?? LaunchAtLoginController()
        self.updates = updates ?? UpdateService()
        self.shellApprovals = resolvedApprovals
        self.generatedTools = resolvedArtifacts
        self.runtime = runtime ?? AppletRuntimeEngine(
            shellApprovals: resolvedApprovals,
            generatedTools: resolvedArtifacts
        )

        self.store.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        self.runtime.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        self.providers.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)

        self.preferences.objectWillChange
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
            .store(in: &cancellables)
    }

    // MARK: - Startup and shutdown

    func bootstrap() async {
        if let bootstrapTask {
            await bootstrapTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performBootstrap()
        }
        bootstrapTask = task
        await task.value
    }

    private func performBootstrap() async {
        AppLog.app.info("Bar Tender bootstrap")
        // Saved tools do not depend on an AI provider. Start them before CLI
        // discovery so a slow or broken provider cannot suppress the menu bar.
        let artifactIssue = restoreCurrentGeneratedToolArtifacts()
        runtime.sync(with: store.applets)
        if selection == nil {
            selection = store.applets.first?.id
        }
        if let loadIssue = store.loadIssue {
            bannerMessage = loadIssue
        } else if let artifactIssue {
            bannerMessage = artifactIssue
        }
        await providers.refreshAvailability()
    }

    /// Reconcile executable artifacts from the persisted manifests before any
    /// polling loop starts. Runners can then treat the shared UUID artifact as
    /// immutable input and never recreate or overwrite it from a stale task.
    private func restoreCurrentGeneratedToolArtifacts() -> String? {
        var failures: [String] = []
        for manifest in store.applets where manifest.kind == .generatedTool {
            do {
                _ = try generatedTools.install(manifest)
            } catch {
                failures.append(manifest.name)
                AppLog.store.error(
                    "Could not restore generated tool artifact for \(manifest.name, privacy: .public): \(error.localizedDescription, privacy: .public)"
                )
            }
        }
        guard !failures.isEmpty else { return nil }
        return failures.count == 1
            ? "Could not restore the executable for “\(failures[0])”. Save or rebuild that tool before running it."
            : "Could not restore executables for \(failures.count) generated tools. Save or rebuild them before running."
    }

    func shutdown() {
        providers.cancelGeneration()
        generation?.phase = .cancelled
        generation?.finishedAt = .now
        cancelAllValidations()
        runtime.stopAll()
    }

    // MARK: - Generation

    private func observeGenerationSession() {
        guard let generation else {
            generationCancellable = nil
            return
        }

        // Include logs so parents that only observe AppModel still refresh while
        // the provider streams output (menu bar panel, empty-state host, etc.).
        generationCancellable = Publishers.Merge5(
            generation.$phase.dropFirst().map { _ in () },
            generation.$logs.dropFirst().map { _ in () },
            generation.$resultManifest.dropFirst().map { _ in () },
            generation.$errorMessage.dropFirst().map { _ in () },
            generation.$finishedAt.dropFirst().map { _ in () }
        )
            .sink { [weak self] _ in
                self?.objectWillChange.send()
            }
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
        replacing existingTool: AppletManifest?,
        initialFeedback: String? = nil
    ) async {
        let resolved = (prompt ?? composerText).trimmingCharacters(in: .whitespacesAndNewlines)
        guard generation?.phase.isActive != true else {
            bannerMessage = "A generation is already running. Cancel it before starting another."
            return
        }
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
            var attemptContext = existingTool
            var iterationFeedback = initialFeedback
            var generatedManifest: AppletManifest?
            var latestCandidate: AppletManifest?
            let maximumAttempts = 3

            for attempt in 1...maximumAttempts {
                guard !session.phase.isCancellationRequested, !Task.isCancelled else {
                    throw ProviderGenerationError.cancelled
                }
                if let iterationFeedback {
                    session.append(
                        stream: .system,
                        attempt == 1
                            ? "Using first-run feedback to repair the tool…"
                            : "Retrying with validation feedback (attempt \(attempt) of \(maximumAttempts))…"
                    )
                    session.append(stream: .system, String(iterationFeedback.prefix(500)))
                }

                do {
                    let manifest = try await providers.generateManifest(
                        prompt: resolved,
                        existingTool: attemptContext,
                        provider: provider,
                        iterationFeedback: iterationFeedback
                    ) { stream, text in
                        session.append(stream: stream, text)
                    }
                    guard !session.phase.isCancellationRequested, !Task.isCancelled else {
                        throw ProviderGenerationError.cancelled
                    }
                    let candidate = ManifestGenerationSupport.replacing(
                        manifest,
                        existingTool: existingTool
                    )
                    latestCandidate = candidate
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
                    guard !session.phase.isCancellationRequested, !Task.isCancelled else {
                        throw ProviderGenerationError.cancelled
                    }
                    generatedManifest = candidate
                    break
                } catch is CancellationError {
                    throw CancellationError()
                } catch let error as ProviderGenerationError {
                    guard !session.phase.isCancellationRequested, !Task.isCancelled else {
                        throw ProviderGenerationError.cancelled
                    }
                    switch error {
                    case .cancelled, .notReady, .authenticationExpired, .noProvidersReady:
                        throw error
                    case .emptyPrompt, .invalidResponse, .missingCommandDependency:
                        guard attempt < maximumAttempts else { throw error }
                        iterationFeedback = error.localizedDescription
                    }
                } catch {
                    guard !session.phase.isCancellationRequested, !Task.isCancelled else {
                        throw ProviderGenerationError.cancelled
                    }
                    guard attempt < maximumAttempts else { throw error }
                    iterationFeedback = error.localizedDescription
                }
                guard !session.phase.isCancellationRequested, !Task.isCancelled else {
                    throw ProviderGenerationError.cancelled
                }
                attemptContext = latestCandidate ?? attemptContext
                session.phase = .running
            }

            guard let candidate = generatedManifest else {
                throw ProviderGenerationError.invalidResponse(
                    "The provider could not produce a valid generated tool after \(maximumAttempts) attempts."
                )
            }
            guard !session.phase.isCancellationRequested, !Task.isCancelled else {
                throw ProviderGenerationError.cancelled
            }
            if let existingTool {
                guard let current = store.applet(id: existingTool.id) else {
                    throw ProviderGenerationError.invalidResponse(
                        "“\(existingTool.name)” was removed while it was being updated, so the stale result was discarded."
                    )
                }
                guard current == existingTool else {
                    throw ProviderGenerationError.invalidResponse(
                        "“\(existingTool.name)” changed while it was being updated. Its newer state was kept; try the update again."
                    )
                }
            }

            let persisted = try persistManifestAndArtifact(candidate, replacing: existingTool)
            let saved = persisted.manifest
            if let executable = persisted.executable {
                session.append(stream: .system, "Installed executable at \(executable.path)")
            }
            let autoApproveEdit = Self.shouldAutoApproveGeneratedToolEdit(
                replacing: existingTool,
                with: saved,
                preferenceEnabled: preferences.autoApproveGeneratedToolEdits,
                previousVersionApproved: existingTool.map(shellApprovals.isApproved) ?? false,
                isAutomaticRepair: initialFeedback != nil
            )
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
            if autoApproveEdit {
                session.append(stream: .system, "Auto-approval selected; starting the revised source’s first-run check…")
                setExecutionApproval(true, for: saved)
            } else if existingTool != nil {
                bannerMessage = shellApprovals.isApproved(saved)
                    ? "Validated “\(saved.name)” and kept it running."
                    : "Updated “\(saved.name)” in place. Review the revised code to run it."
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
                session.errorMessage = nil
                session.finishedAt = .now
                session.append(stream: .system, "Cancelled.")
            default:
                session.phase = .failed
                session.errorMessage = error.localizedDescription
                session.finishedAt = .now
                session.append(stream: .system, error.localizedDescription)
                bannerMessage = error.localizedDescription
            }
        } catch {
            session.phase = .failed
            session.errorMessage = error.localizedDescription
            session.finishedAt = .now
            session.append(stream: .system, error.localizedDescription)
            bannerMessage = error.localizedDescription
        }
    }

    func cancelGeneration() {
        guard let generation, generation.phase.isActive else { return }
        providers.cancelGeneration()
        guard generation.phase != .cancelling else { return }
        generation.phase = .cancelling
        generation.append(stream: .system, "Cancelling generation…")
    }

    // MARK: - Tool mutations

    func deleteSelected() {
        guard let id = selection else { return }
        deleteApplet(id: id)
    }

    func deleteApplet(id: UUID) {
        guard generation?.phase.isActive != true else {
            bannerMessage = "Cancel the current generation before deleting a tool."
            return
        }
        guard let applet = store.applet(id: id) else { return }

        if preferences.confirmBeforeDelete {
            guard LibraryFilePanels.confirmDelete(name: applet.name) else { return }
        }

        do {
            cancelValidation(id: id)
            try store.delete(id: id)
            shellApprovals.revoke(id: id)
            var artifactCleanupError: Error?
            do {
                try generatedTools.remove(id: id)
            } catch {
                artifactCleanupError = error
                AppLog.store.error("Could not remove generated tool artifact: \(error.localizedDescription, privacy: .public)")
            }
            runtime.stop(id: id)
            runtime.sync(with: store.applets)
            if selection == id {
                selection = store.applets.first?.id
            }
            if let artifactCleanupError {
                bannerMessage = "“\(applet.name)” was removed, but its generated files need manual cleanup: \(artifactCleanupError.localizedDescription)"
            }
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    func saveEdits(_ manifest: AppletManifest) {
        do {
            let previous = store.applet(id: manifest.id)
            let saved = try persistManifestAndArtifact(manifest, replacing: previous).manifest
            runtime.restart(manifest: saved)
            runtime.sync(with: store.applets)
            bannerMessage = "Saved “\(saved.name)”."
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    /// Installs executable content before publishing the manifest. If either
    /// side fails, restore the previous artifact so a failed save cannot leave
    /// a ghost manifest or destroy the last runnable revision.
    private func persistManifestAndArtifact(
        _ candidate: AppletManifest,
        replacing previous: AppletManifest?
    ) throws -> PersistedManifest {
        cancelValidation(id: candidate.id)
        var executable: URL?

        do {
            if candidate.kind == .generatedTool {
                executable = try generatedTools.install(candidate)
            } else if previous?.kind == .generatedTool {
                try generatedTools.remove(id: candidate.id)
            }
        } catch {
            restoreArtifact(afterFailedPersistenceOf: candidate, previous: previous)
            throw error
        }

        do {
            let saved = try store.upsert(candidate)
            return PersistedManifest(manifest: saved, executable: executable)
        } catch {
            restoreArtifact(afterFailedPersistenceOf: candidate, previous: previous)
            throw error
        }
    }

    private func restoreArtifact(
        afterFailedPersistenceOf candidate: AppletManifest,
        previous: AppletManifest?
    ) {
        do {
            if let previous, previous.kind == .generatedTool {
                _ = try generatedTools.install(previous)
            } else {
                try generatedTools.remove(id: candidate.id)
            }
        } catch {
            AppLog.store.error(
                "Could not restore generated tool artifact after a failed save: \(error.localizedDescription, privacy: .public)"
            )
        }
    }

    func toggleEnabled(_ manifest: AppletManifest) {
        setEnabled(manifest, enabled: !manifest.enabled)
    }

    func setEnabled(_ manifest: AppletManifest, enabled: Bool) {
        do {
            cancelValidation(id: manifest.id)
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
                cancelValidation(id: manifest.id)
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

    // MARK: - Execution approval

    func isShellApproved(_ manifest: AppletManifest) -> Bool {
        shellApprovals.isApproved(manifest)
    }

    func isExecutionApproved(_ manifest: AppletManifest) -> Bool {
        shellApprovals.isApproved(manifest)
    }

    func isValidatingExecution(_ manifest: AppletManifest) -> Bool {
        validationTokens[manifest.id] != nil
    }

    static func shouldAutoApproveGeneratedToolEdit(
        replacing existingTool: AppletManifest?,
        with savedTool: AppletManifest,
        preferenceEnabled: Bool,
        previousVersionApproved: Bool,
        isAutomaticRepair: Bool
    ) -> Bool {
        guard preferenceEnabled,
              previousVersionApproved,
              !isAutomaticRepair,
              let existingTool,
              existingTool.id == savedTool.id,
              existingTool.kind == .generatedTool,
              savedTool.kind == .generatedTool else {
            return false
        }

        return ShellApprovalStore.fingerprint(for: existingTool)
            != ShellApprovalStore.fingerprint(for: savedTool)
    }

    func setShellApproval(_ approved: Bool, for manifest: AppletManifest) {
        setExecutionApproval(approved, for: manifest)
    }

    func setExecutionApproval(_ approved: Bool, for manifest: AppletManifest) {
        if approved, manifest.kind == .generatedTool {
            guard generation?.phase.isActive != true else {
                bannerMessage = "Wait for the current generation to finish before running this tool."
                return
            }
            guard store.applet(id: manifest.id) == manifest else {
                bannerMessage = "This tool changed before approval. Review the current source and try again."
                return
            }
            cancelValidation(id: manifest.id)
            // Approval becomes durable only after this exact revision completes
            // its first-run check. Cancelling the check must not turn a
            // provisional decision into an executable-on-next-launch state.
            shellApprovals.setApproved(false, for: manifest)
            runtime.stop(id: manifest.id)
            bannerMessage = "Testing “\(manifest.name)” before putting it live…"
            let token = UUID()
            validationTokens[manifest.id] = token
            validationTasks[manifest.id] = Task { [weak self] in
                await self?.validateApprovedGeneratedTool(manifest, token: token)
            }
            objectWillChange.send()
            return
        }

        cancelValidation(id: manifest.id)
        shellApprovals.setApproved(approved, for: manifest)
        if let persisted = store.applet(id: manifest.id) {
            runtime.restart(manifest: persisted)
        }
        objectWillChange.send()
    }

    private func validateApprovedGeneratedTool(_ manifest: AppletManifest, token: UUID) async {
        defer {
            if validationTokens[manifest.id] == token {
                validationTokens[manifest.id] = nil
                validationTasks[manifest.id] = nil
                objectWillChange.send()
            }
        }

        let result = await GeneratedToolRunner.run(
            manifest: manifest,
            approved: true,
            artifactStore: generatedTools
        )

        guard !Task.isCancelled,
              validationTokens[manifest.id] == token,
              let persisted = store.applet(id: manifest.id),
              persisted == manifest else { return }

        if let output = result.output, output.healthy {
            shellApprovals.setApproved(true, for: persisted)
            runtime.startValidatedGeneratedTool(manifest: persisted, output: output)
            runtime.sync(with: store.applets)
            objectWillChange.send()
            bannerMessage = persisted.enabled
                ? "“\(persisted.name)” passed its first-run check and is live."
                : "“\(persisted.name)” passed its first-run check. Enable it when you are ready."
            return
        }

        if generation?.phase.isActive == true {
            runtime.restart(manifest: persisted)
            runtime.sync(with: store.applets)
            bannerMessage = "“\(persisted.name)” still needs attention. Cancel the current generation to send the first-run result back to \(providers.selectedProvider.displayName)."
            return
        }

        guard providers.availability.isReady else {
            runtime.restart(manifest: persisted)
            runtime.sync(with: store.applets)
            bannerMessage = "“\(persisted.name)” needs attention. Recheck the provider to enable automatic repair."
            return
        }

        let feedback = ManifestGenerationSupport.runtimeRepairFeedback(for: result)
        bannerMessage = "The first run needs attention. Sending the result back to \(providers.selectedProvider.displayName)…"
        let originalRequest = persisted.sourcePrompt.trimmingCharacters(in: .whitespacesAndNewlines)
        await generateTool(
            from: originalRequest.isEmpty ? "Make this menu bar tool work as intended." : originalRequest,
            replacing: persisted,
            initialFeedback: feedback
        )

        if generation?.phase != .succeeded,
           let current = store.applet(id: manifest.id) {
            runtime.restart(manifest: current)
            runtime.sync(with: store.applets)
        }
    }

    private func cancelValidation(id: UUID) {
        let hadToken = validationTokens.removeValue(forKey: id) != nil
        let task = validationTasks.removeValue(forKey: id)
        task?.cancel()
        if hadToken || task != nil {
            objectWillChange.send()
        }
    }

    private func cancelAllValidations() {
        let hadValidations = !validationTokens.isEmpty || !validationTasks.isEmpty
        for task in validationTasks.values {
            task.cancel()
        }
        validationTasks.removeAll()
        validationTokens.removeAll()
        if hadValidations {
            objectWillChange.send()
        }
    }

    // MARK: - Library management

    func clearLibrary() {
        guard generation?.phase.isActive != true else {
            bannerMessage = "Cancel the current generation before clearing the library."
            return
        }

        do {
            cancelAllValidations()
            try store.removeAll()
            shellApprovals.removeAll()
            var artifactCleanupError: Error?
            do {
                try generatedTools.removeAll()
            } catch {
                artifactCleanupError = error
                AppLog.store.error("Could not remove generated tool artifacts: \(error.localizedDescription, privacy: .public)")
            }
            runtime.stopAll()
            runtime.sync(with: store.applets)
            selection = nil
            bannerMessage = artifactCleanupError.map {
                "Library cleared, but some generated files could not be removed: \($0.localizedDescription)"
            } ?? "Library cleared."
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    func addSampleLibrary() {
        guard generation?.phase.isActive != true else {
            bannerMessage = "Cancel the current generation before changing the library."
            return
        }

        do {
            var addedCount = 0
            for sample in AppletManifest.samples {
                if !store.applets.contains(where: { $0.name == sample.name && $0.kind == sample.kind }) {
                    try store.upsert(sample)
                    addedCount += 1
                }
            }
            runtime.sync(with: store.applets)
            selection = store.applets.first?.id
            bannerMessage = addedCount == 0
                ? "The built-in samples are already in your library."
                : "Added \(addedCount) built-in sample\(addedCount == 1 ? "" : "s")."
        } catch {
            bannerMessage = error.localizedDescription
        }
    }

    func exportLibrary() {
        guard let url = LibraryFilePanels.chooseExportURL() else { return }

        do {
            try store.exportArchiveData().write(to: url, options: [.atomic])
            bannerMessage = "Exported \(store.applets.count) tool(s)."
        } catch {
            bannerMessage = "Could not export the library: \(error.localizedDescription)"
        }
    }

    func importLibrary() {
        guard generation?.phase.isActive != true else {
            bannerMessage = "Cancel the current generation before importing a library."
            return
        }

        guard let url = LibraryFilePanels.chooseImportURL() else { return }
        guard let mode = LibraryFilePanels.confirmImport() else { return }

        do {
            let data = try Data(contentsOf: url)
            // Validate + preflight artifact installs before mutating the live library.
            let imported = try store.validatedManifests(from: data)
            let stagingRoot = FileManager.default.temporaryDirectory
                .appendingPathComponent("BarTender-Import-\(UUID().uuidString)", isDirectory: true)
            defer { try? FileManager.default.removeItem(at: stagingRoot) }
            let staging = GeneratedToolArtifactStore(rootURL: stagingRoot)
            for manifest in imported where manifest.kind == .generatedTool {
                _ = try staging.install(manifest)
            }

            let previousApplets = store.applets
            let previousApprovals = shellApprovals.snapshot()
            // Stop live tasks before swapping artifacts so stale polling loops
            // cannot reinstall pre-import generatedSource over the import.
            cancelAllValidations()
            runtime.stopAll()

            do {
                try store.applyImport(imported, mode: mode)
                if mode == .replace {
                    shellApprovals.removeAll()
                    try generatedTools.removeAll()
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
                selection = imported.first?.id ?? store.applets.first?.id
                bannerMessage = "Imported \(imported.count) tool(s). Review generated source before running it."
            } catch {
                let importError = error
                var rollbackErrors: [String] = []
                // Roll back library, approvals, and generated-tool artifacts.
                do {
                    try store.replaceAll(previousApplets)
                } catch {
                    rollbackErrors.append("library: \(error.localizedDescription)")
                }
                shellApprovals.restore(previousApprovals)
                do {
                    try restoreGeneratedToolArtifacts(
                        from: previousApplets,
                        removingImported: imported,
                        replaceMode: mode == .replace
                    )
                } catch {
                    rollbackErrors.append("generated files: \(error.localizedDescription)")
                }
                runtime.sync(with: store.applets)
                if rollbackErrors.isEmpty {
                    throw importError
                }
                throw AppletStoreError.persistenceFailed(
                    "Import failed: \(importError.localizedDescription). Rollback also failed for \(rollbackErrors.joined(separator: "; "))."
                )
            }
        } catch {
            bannerMessage = "Could not import the library: \(error.localizedDescription)"
        }
    }

    /// Reinstalls generated-tool artifacts from a prior library snapshot after a failed import.
    private func restoreGeneratedToolArtifacts(
        from previousApplets: [AppletManifest],
        removingImported imported: [AppletManifest],
        replaceMode: Bool
    ) throws {
        if replaceMode {
            // Replace may have wiped the artifact root; rebuild from the snapshot.
            try? generatedTools.removeAll()
            for manifest in previousApplets where manifest.kind == .generatedTool {
                _ = try generatedTools.install(manifest)
            }
            return
        }
        // Merge: remove imported-only or type-changed artifacts, then reinstall
        // any previous generated tools that may have been overwritten.
        for manifest in imported {
            try generatedTools.remove(id: manifest.id)
        }
        for manifest in previousApplets where manifest.kind == .generatedTool {
            _ = try generatedTools.install(manifest)
        }
    }

    // MARK: - Diagnostics and permissions

    func exportDiagnostics() {
        guard let url = LibraryFilePanels.chooseDiagnosticsURL() else { return }

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
