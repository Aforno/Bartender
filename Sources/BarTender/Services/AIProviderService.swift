import Foundation

/// Discovers and invokes local AI CLIs (Codex, Claude, Grok, Gemini, Antigravity).
/// Uses only documented flags inspected from each CLI's `--help`.
@MainActor
final class AIProviderService: ObservableObject {
    @Published var selectedProvider: AIProvider {
        didSet {
            defaults.set(selectedProvider.rawValue, forKey: Self.selectedProviderKey)
        }
    }

    /// Concrete model used for generation (shown in the composer model selector).
    @Published var selectedModel: AIModelOption {
        didSet {
            defaults.set(selectedModel.id, forKey: Self.selectedModelKey)
        }
    }

    @Published private(set) var statuses: [AIProvider: ProviderAvailability] = [
        .codex: .checking,
        .claude: .checking,
        .grok: .checking,
        .gemini: .checking,
        .agy: .checking
    ]

    /// User preference: which providers appear in the model selector and may be used for generation.
    @Published private(set) var enabledProviders: Set<AIProvider> = Set(AIProvider.allCases) {
        didSet {
            let raw = enabledProviders.map(\.rawValue).sorted()
            defaults.set(raw, forKey: Self.enabledProvidersKey)
        }
    }

    /// Cached catalog of models grouped for the picker.
    @Published private(set) var availableModels: [AIModelOption] = []

    private let runner = ProcessRunner()
    private let defaults: UserDefaults
    private let environmentLoader: () async -> [String: String]
    private let homeDirectoryURL: URL
    private let modelProvider: (AIProvider) -> [AIModelOption]
    private let executableResolver: (String, [String: String]) -> String?
    private var availabilityRefreshTask: Task<Void, Never>?
    private var generationTask: Task<AppletManifest, Error>?
    private var generationRunner: ProcessRunner?
    private var generationSessionID: UUID?
    private var generationCancellationRequested = false

    private static let selectedProviderKey = "BarTender.selectedProvider"
    private static let selectedModelKey = "BarTender.selectedModel"
    private static let enabledProvidersKey = "BarTender.enabledProviders"

    init(
        defaults: UserDefaults = .standard,
        environmentLoader: @escaping () async -> [String: String] = {
            await ShellEnvironment.loginEnvironment()
        },
        homeDirectoryURL: URL = URL(fileURLWithPath: NSHomeDirectory()),
        modelProvider: @escaping (AIProvider) -> [AIModelOption] = ModelCatalog.models,
        executableResolver: @escaping (String, [String: String]) -> String? = {
            ShellEnvironment.which($0, environment: $1)
        }
    ) {
        self.defaults = defaults
        self.environmentLoader = environmentLoader
        self.homeDirectoryURL = homeDirectoryURL
        self.modelProvider = modelProvider
        self.executableResolver = executableResolver

        let provider: AIProvider
        if let raw = defaults.string(forKey: Self.selectedProviderKey),
           let parsed = AIProvider(rawValue: raw) {
            provider = parsed
        } else {
            provider = .codex
        }

        // Initialize stored properties, then refine from disk catalogs.
        selectedProvider = provider
        selectedModel = AIModelOption(
            provider: provider,
            modelID: "default",
            displayName: provider.displayName,
            isDefault: true
        )
        availableModels = AIProvider.allCases.flatMap(modelProvider)

        if let stored = defaults.array(forKey: Self.enabledProvidersKey) as? [String] {
            let parsed = Set(stored.compactMap(AIProvider.init(rawValue:)))
            // Never allow an empty set — keep all on if storage is corrupt.
            enabledProviders = parsed.isEmpty ? Set(AIProvider.allCases) : parsed
        } else {
            enabledProviders = Set(AIProvider.allCases)
        }

        if let saved = defaults.string(forKey: Self.selectedModelKey),
           let match = availableModels.first(where: { $0.id == saved }),
           enabledProviders.contains(match.provider) {
            selectedModel = match
            selectedProvider = match.provider
        } else {
            // Set iteration order is nondeterministic; fall back in declaration order.
            let preferred = enabledProviders.contains(provider)
                ? provider
                : (firstEnabledProvider ?? provider)
            selectedModel = preferredModel(for: preferred)
            selectedProvider = selectedModel.provider
        }
    }

    var availability: ProviderAvailability {
        guard isProviderEnabled(selectedProvider) else {
            return .unavailable(.notFound)
        }
        return statuses[selectedProvider] ?? .checking
    }

    var anyProviderReady: Bool {
        enabledReadyProviders.contains { statuses[$0]?.isReady == true }
    }

    /// Providers that are both user-enabled and CLI-ready.
    var readyProviders: [AIProvider] {
        enabledReadyProviders
    }

    private var enabledReadyProviders: [AIProvider] {
        AIProvider.allCases.filter {
            enabledProviders.contains($0) && statuses[$0]?.isReady == true
        }
    }

    /// Models from enabled + ready providers. Falls back to enabled providers' catalogs.
    var selectableModels: [AIModelOption] {
        let enabled = AIProvider.allCases.filter { enabledProviders.contains($0) }
        let ready = enabledReadyProviders
        let pool = ready.isEmpty ? enabled : ready
        let filtered = availableModels.filter { pool.contains($0.provider) }
        return filtered
    }

    func status(for provider: AIProvider) -> ProviderAvailability {
        statuses[provider] ?? .checking
    }

    func isProviderEnabled(_ provider: AIProvider) -> Bool {
        enabledProviders.contains(provider)
    }

    /// The first enabled provider in `AIProvider.allCases` order (deterministic,
    /// unlike `Set.first`).
    private var firstEnabledProvider: AIProvider? {
        AIProvider.allCases.first(where: enabledProviders.contains)
    }

    /// Turns a provider on/off in Settings. At least one provider must stay enabled.
    func setProviderEnabled(_ provider: AIProvider, enabled: Bool) {
        var next = enabledProviders
        if enabled {
            next.insert(provider)
        } else {
            guard next.count > 1 else { return }
            next.remove(provider)
        }
        enabledProviders = next

        // If the active provider was disabled, hop to another enabled one.
        if !enabledProviders.contains(selectedProvider),
           let fallback = firstEnabledProvider {
            selectProvider(fallback)
        }

        // Drop selected model if its provider is now off.
        if !enabledProviders.contains(selectedModel.provider),
           let fallback = selectableModels.first ?? firstEnabledProvider.map({ preferredModel(for: $0) }) {
            selectModel(fallback)
        }

        objectWillChange.send()
    }

    func models(for provider: AIProvider) -> [AIModelOption] {
        availableModels.filter { $0.provider == provider }
    }

    /// Picks a concrete model and switches the active provider to match.
    func selectModel(_ model: AIModelOption) {
        guard enabledProviders.contains(model.provider) else { return }
        selectedModel = model
        if selectedProvider != model.provider {
            selectedProvider = model.provider
        }
    }

    /// Picks a provider and lands on its preferred model.
    func selectProvider(_ provider: AIProvider) {
        guard enabledProviders.contains(provider) else { return }
        selectedProvider = provider
        if selectedModel.provider != provider {
            selectedModel = preferredModel(for: provider)
        }
    }

    func refreshAvailability() async {
        if let availabilityRefreshTask {
            await availabilityRefreshTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            await self.performAvailabilityRefresh()
        }
        availabilityRefreshTask = task
        await task.value
        availabilityRefreshTask = nil
    }

    private func performAvailabilityRefresh() async {
        for provider in AIProvider.allCases {
            statuses[provider] = .checking
        }

        let environment = await environmentLoader()
        // Probe providers concurrently. Each probe awaits ProcessRunner (an actor),
        // so independent CLIs progress in parallel; status is published as each finishes.
        await withTaskGroup(of: (AIProvider, ProviderAvailability).self) { group in
            for provider in AIProvider.allCases {
                group.addTask { @MainActor in
                    let status = await self.probe(provider, environment: environment)
                    return (provider, status)
                }
            }
            for await (provider, status) in group {
                statuses[provider] = status
            }
        }

        refreshModelCatalog()

        // Prefer keeping the user's selection if ready; otherwise fall back to first ready provider/model.
        if !isProviderEnabled(selectedProvider) || !availability.isReady,
           let fallback = readyProviders.first {
            selectProvider(fallback)
            AppLog.provider.info("Selected provider fell back to \(fallback.rawValue, privacy: .public)")
        } else if !selectableModels.contains(where: { $0.id == selectedModel.id }) {
            selectedModel = preferredModel(for: selectedProvider)
        }
    }

    func refreshModelCatalog() {
        availableModels = AIProvider.allCases.flatMap(modelProvider)
        AppLog.provider.info("Model catalog loaded (\(self.availableModels.count, privacy: .public) models)")
    }

    private func preferredModel(for provider: AIProvider) -> AIModelOption {
        let list = modelProvider(provider)
        if let def = list.first(where: \.isDefault) { return def }
        if let first = list.first { return first }
        return AIModelOption(provider: provider, modelID: "default", displayName: provider.displayName, isDefault: true)
    }

    func cancelGeneration() {
        generationCancellationRequested = true
        generationTask?.cancel()
        // Capture and clear the runner on this actor hop so a later generate
        // cannot publish a new runner that this cancellation then kills.
        let runner = generationRunner
        generationRunner = nil
        guard let runner else { return }
        Task {
            await runner.cancel()
        }
    }

    func generateManifest(
        prompt: String,
        existingTool: AppletManifest? = nil,
        provider: AIProvider? = nil,
        iterationFeedback: String? = nil,
        onLog: @escaping @MainActor (ProviderLogLine.Stream, String) -> Void
    ) async throws -> AppletManifest {
        generationCancellationRequested = false
        let chosen = provider ?? selectedProvider
        guard case .ready(let installation) = statuses[chosen] else {
            throw ProviderGenerationError.notReady(chosen)
        }

        let trimmed = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ProviderGenerationError.emptyPrompt
        }

        let env = await environmentLoader()
        let tempRoot = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTender-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempRoot) }

        let model = (chosen == selectedModel.provider)
            ? selectedModel
            : preferredModel(for: chosen)

        let fullPrompt = ManifestGenerationSupport.buildPrompt(
            userRequest: trimmed,
            existingTool: existingTool,
            iterationFeedback: iterationFeedback
        )
        let invocation = try buildInvocation(
            provider: chosen,
            installation: installation,
            model: model,
            prompt: fullPrompt,
            tempRoot: tempRoot
        )

        onLog(.system, "Provider: \(chosen.displayName)")
        onLog(.system, "Model: \(model.modelID) (\(model.displayName))")
        onLog(.system, "Launching: \(installation.executablePath)")
        onLog(.system, "Version: \(installation.version)")
        onLog(.system, "Args: \(Self.redactedArgumentList(invocation.arguments))")
        onLog(.system, existingTool.map { "Mode: Revising \($0.name) in place" } ?? "Mode: Creating a new tool")
        if iterationFeedback != nil {
            onLog(.system, "Feedback: Retrying with validator or first-run diagnostics")
        }
        onLog(.system, "Prompt size: \(fullPrompt.count) characters")

        let localRunner = ProcessRunner()
        let sessionID = UUID()
        generationSessionID = sessionID
        generationRunner = localRunner

        guard !generationCancellationRequested else {
            if generationSessionID == sessionID {
                generationRunner = nil
                generationSessionID = nil
            }
            throw ProviderGenerationError.cancelled
        }

        let task = Task<AppletManifest, Error> {
            let result = try await localRunner.run(
                executable: installation.executablePath,
                arguments: invocation.arguments,
                environment: env,
                currentDirectory: invocation.currentDirectory,
                onStdout: { chunk in
                    Task { @MainActor in onLog(.stdout, chunk) }
                },
                onStderr: { chunk in
                    Task { @MainActor in onLog(.stderr, chunk) }
                }
            )

            if result.cancelled || Task.isCancelled {
                throw ProviderGenerationError.cancelled
            }
            let message = try Self.resolveMessage(
                provider: chosen,
                result: result,
                outputFile: invocation.outputFile
            )
            let manifest = try ManifestGenerationSupport.makeManifest(from: message, sourcePrompt: trimmed)
            guard manifest.kind == .generatedTool else {
                throw ProviderGenerationError.invalidResponse(
                    "The provider returned a pre-made \(manifest.kind.displayName) instead of generating a dedicated tool. Try again."
                )
            }
            return manifest
        }

        generationTask = task
        defer {
            // Only the session that still owns generation may clear shared
            // state. A superseded run must not nil the next runner or reset
            // a newer cancellation flag.
            if generationSessionID == sessionID {
                generationTask = nil
                if generationRunner === localRunner {
                    generationRunner = nil
                }
                generationCancellationRequested = false
                generationSessionID = nil
            }
        }
        do {
            let manifest = try await task.value
            guard !generationCancellationRequested else {
                throw ProviderGenerationError.cancelled
            }
            return manifest
        } catch is CancellationError {
            throw ProviderGenerationError.cancelled
        } catch ProcessRunnerError.cancelled {
            throw ProviderGenerationError.cancelled
        } catch let error as ProviderGenerationError {
            if case .authenticationExpired(let provider) = error {
                statuses[provider] = .unavailable(.notAuthenticated(
                    "The saved session expired or was revoked. \(provider.loginHint)"
                ))
            }
            throw error
        }
    }

    // MARK: - Probe

    private func probe(
        _ provider: AIProvider,
        environment: [String: String]
    ) async -> ProviderAvailability {
        guard let path = executableResolver(provider.executableName, environment) else {
            AppLog.provider.error("\(provider.rawValue, privacy: .public) CLI not found on PATH")
            return .unavailable(.notFound)
        }

        do {
            let version = try await readVersion(provider: provider, path: path, env: environment)
            let auth = try await readAuth(provider: provider, path: path, env: environment)
            if let auth, auth.ok == false {
                return .unavailable(.notAuthenticated(auth.summary))
            }
            let install = ProviderInstallation(
                provider: provider,
                executablePath: path,
                version: version,
                authSummary: auth?.summary ?? "Installed"
            )
            AppLog.provider.info("\(provider.rawValue, privacy: .public) ready at \(path, privacy: .public) (\(version, privacy: .public))")
            return .ready(install)
        } catch let error as ProbeError {
            switch error {
            case .version(let detail):
                return .unavailable(.versionCheckFailed(detail))
            case .auth(let detail):
                return .unavailable(.loginCheckFailed(detail))
            }
        } catch {
            return .unavailable(.loginCheckFailed(error.localizedDescription))
        }
    }

    private enum ProbeError: Error {
        case version(String)
        case auth(String)
    }

    private struct AuthProbe {
        var ok: Bool
        var summary: String
    }

    private enum GeminiAuthType: String {
        case oauth = "oauth-personal"
        case apiKey = "gemini-api-key"
        case vertexAI = "vertex-ai"
        case computeADC = "compute-default-credentials"
    }

    private enum GeminiAuthSelection {
        case none
        case supported(GeminiAuthType)
        case unsupported
    }

    private func readVersion(provider: AIProvider, path: String, env: [String: String]) async throws -> String {
        // Documented version flags:
        // codex/claude/grok/gemini/agy --version
        let args: [String]
        switch provider {
        case .codex, .claude, .grok, .gemini, .agy:
            args = ["--version"]
        }
        let result = try await runner.run(executable: path, arguments: args, environment: env, timeout: 15)
        guard !result.timedOut, result.exitCode == 0 else {
            let detail = (result.stderr.isEmpty ? result.stdout : result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw ProbeError.version(detail.isEmpty ? "Exit code \(result.exitCode)" : detail)
        }
        let version = (result.stdout.isEmpty ? result.stderr : result.stdout)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard !version.isEmpty else {
            throw ProbeError.version("Empty version output")
        }
        return version
    }

    private func readAuth(provider: AIProvider, path: String, env: [String: String]) async throws -> AuthProbe? {
        switch provider {
        case .codex:
            // Documented: `codex login status`
            let result = try await runner.run(
                executable: path,
                arguments: ["login", "status"],
                environment: env,
                timeout: 20
            )
            if result.timedOut {
                throw ProbeError.auth("Login status check timed out.")
            }
            let output = (result.stdout + "\n" + result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if result.exitCode != 0 || Self.looksUnauthenticated(output) {
                return AuthProbe(ok: false, summary: output.isEmpty ? "Exit code \(result.exitCode)" : output)
            }
            return AuthProbe(ok: true, summary: output.isEmpty ? "Authenticated" : output)

        case .claude:
            // Documented: `claude auth status` (JSON with loggedIn)
            let result = try await runner.run(
                executable: path,
                arguments: ["auth", "status"],
                environment: env,
                timeout: 20
            )
            if result.timedOut {
                throw ProbeError.auth("Auth status check timed out.")
            }
            let output = (result.stdout + "\n" + result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if let data = result.stdout.data(using: .utf8),
               let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let loggedIn = json["loggedIn"] as? Bool {
                if loggedIn {
                    let method = (json["authMethod"] as? String) ?? "signed in"
                    let email = (json["email"] as? String) ?? ""
                    let summary = email.isEmpty ? "Logged in (\(method))" : "\(email) · \(method)"
                    return AuthProbe(ok: true, summary: summary)
                }
                return AuthProbe(ok: false, summary: output.isEmpty ? "loggedIn=false" : output)
            }
            if result.exitCode != 0 || Self.looksUnauthenticated(output) {
                return AuthProbe(ok: false, summary: output.isEmpty ? "Exit code \(result.exitCode)" : output)
            }
            // Non-JSON but exit 0: treat as ready.
            return AuthProbe(ok: true, summary: output.isEmpty ? "Authenticated" : output)

        case .grok:
            // Grok has no `login status` command. `grok models` is documented,
            // non-generative, and forces an expired OAuth token refresh.
            let authURL = homeDirectoryURL.appendingPathComponent(".grok/auth.json")
            guard FileManager.default.fileExists(atPath: authURL.path) else {
                return AuthProbe(ok: false, summary: "Missing ~/.grok/auth.json — run `grok login`.")
            }
            // Confirm the file is non-empty JSON without exposing credentials.
            guard
                let data = try? Data(contentsOf: authURL),
                !data.isEmpty,
                let obj = try? JSONSerialization.jsonObject(with: data),
                (obj as? [String: Any])?.isEmpty == false
            else {
                return AuthProbe(ok: false, summary: "Auth file present but empty — run `grok login`.")
            }
            let result = try await runner.run(
                executable: path,
                arguments: ["models"],
                environment: env,
                timeout: 20
            )
            if result.timedOut {
                throw ProbeError.auth("Model/auth check timed out.")
            }
            let output = (result.stdout + "\n" + result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if result.exitCode != 0 || Self.looksUnauthenticated(output) {
                return AuthProbe(ok: false, summary: "Authentication expired or unavailable — run `grok login`.")
            }
            return AuthProbe(ok: true, summary: "Authenticated")

        case .gemini:
            // Gemini has no `login status` command. Match its documented configuration
            // roots and non-interactive authentication environment without surfacing
            // credential values in status text or logs.
            return readGeminiAuth(environment: env)

        case .agy:
            // Antigravity CLI stores OAuth under ~/.gemini/antigravity-cli/.
            // `agy models` is non-generative and fails closed when auth is missing/expired.
            let tokenURL = homeDirectoryURL
                .appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
            guard FileManager.default.fileExists(atPath: tokenURL.path) else {
                return AuthProbe(ok: false, summary: "Missing Antigravity OAuth token — run `agy` and sign in.")
            }
            guard
                let data = try? Data(contentsOf: tokenURL),
                !data.isEmpty
            else {
                return AuthProbe(ok: false, summary: "Auth token present but empty — run `agy` and sign in.")
            }
            let result = try await runner.run(
                executable: path,
                arguments: ["models"],
                environment: env,
                timeout: 20
            )
            if result.timedOut {
                throw ProbeError.auth("Model/auth check timed out.")
            }
            let output = (result.stdout + "\n" + result.stderr)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if result.exitCode != 0 || Self.looksUnauthenticated(output) {
                return AuthProbe(ok: false, summary: "Authentication expired or unavailable — run `agy` and sign in.")
            }
            return AuthProbe(ok: true, summary: "Authenticated")
        }
    }

    // MARK: - Invocation builders (documented flags only)

    private struct Invocation {
        var arguments: [String]
        var currentDirectory: String?
        var outputFile: URL?
    }

    private func buildInvocation(
        provider: AIProvider,
        installation: ProviderInstallation,
        model: AIModelOption,
        prompt: String,
        tempRoot: URL
    ) throws -> Invocation {
        // All supported CLIs document `-m` / `--model <MODEL>`.
        let modelArgs = modelFlag(for: provider, modelID: model.modelID)

        switch provider {
        case .codex:
            // Documented: codex exec -m <model> --skip-git-repo-check --ephemeral --color never
            // --json --sandbox read-only --output-schema <file> --output-last-message <file> <prompt>
            let schemaURL = try ManifestGenerationSupport.writeSchema(to: tempRoot)
            let outputURL = tempRoot.appendingPathComponent("last-message.txt")
            return Invocation(
                arguments: [
                    "exec"
                ] + modelArgs + [
                    "--skip-git-repo-check",
                    "--ephemeral",
                    "--color", "never",
                    "--json",
                    "--sandbox", "read-only",
                    "--output-schema", schemaURL.path,
                    "--output-last-message", outputURL.path,
                    prompt
                ],
                currentDirectory: tempRoot.path,
                outputFile: outputURL
            )

        case .claude:
            // Documented: claude -p/--print --model <model> --output-format json --json-schema <schema>
            // --tools "" disables tools for pure JSON generation (MVP safety).
            // --permission-mode dontAsk avoids interactive prompts.
            // --no-session-persistence for ephemeral runs.
            let schema = try ManifestGenerationSupport.schemaJSONString()
            // Compact schema for argv.
            let compactSchema = schema
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
            return Invocation(
                arguments: [
                    "-p"
                ] + modelArgs + [
                    "--output-format", "json",
                    "--json-schema", compactSchema,
                    "--tools", "",
                    "--permission-mode", "dontAsk",
                    "--no-session-persistence",
                    prompt
                ],
                currentDirectory: tempRoot.path,
                outputFile: nil
            )

        case .grok:
            // Documented: grok -p/--single <prompt> -m <model> --json-schema <schema>
            // --json-schema implies --output-format json.
            // --permission-mode dontAsk avoids interactive tool approval.
            // --tools "" / empty allow-list keeps the run answer-only when supported.
            let schema = try ManifestGenerationSupport.schemaJSONString()
            let compactSchema = schema
                .components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .joined(separator: " ")
            return Invocation(
                arguments: [
                    "--single", prompt
                ] + modelArgs + [
                    "--json-schema", compactSchema,
                    "--output-format", "json",
                    "--permission-mode", "dontAsk",
                    "--tools", "",
                    "--max-turns", "2",
                    "--no-subagents",
                    "--disable-web-search"
                ],
                currentDirectory: tempRoot.path,
                outputFile: nil
            )

        case .gemini:
            // Documented: gemini -p/--prompt <prompt> -m/--model <model>
            // --output-format json wraps the answer in {response, stats, error}.
            // --approval-mode plan is read-only; --skip-trust avoids workspace prompts.
            // No JSON-schema flag — the prompt requires a bare manifest object.
            return Invocation(
                arguments: [
                    "--prompt", prompt
                ] + modelArgs + [
                    "--output-format", "json",
                    "--approval-mode", "plan",
                    "--skip-trust"
                ],
                currentDirectory: tempRoot.path,
                outputFile: nil
            )

        case .agy:
            // Documented: agy --print/--prompt/-p <prompt> --model <model>
            // --mode plan keeps the run non-mutating; --sandbox enables terminal restrictions.
            // A zero print timeout disables agy's built-in five-minute wait deadline;
            // ProcessRunner cancellation still terminates the child process.
            // No JSON-schema / output-format flags — stdout is the assistant text.
            return Invocation(
                arguments: Self.antigravityPrintArguments(
                    prompt: prompt,
                    modelArguments: modelArgs
                ),
                currentDirectory: tempRoot.path,
                outputFile: nil
            )
        }
    }

    static func antigravityPrintArguments(
        prompt: String,
        modelArguments: [String]
    ) -> [String] {
        [
            "--print", prompt
        ] + modelArguments + [
            "--print-timeout=0s",
            "--mode", "plan",
            "--sandbox"
        ]
    }

    /// Redacts prompt payloads and large schema blobs from display logs while
    /// keeping useful operational flags (model, mode, paths).
    nonisolated static func redactedArgumentList(_ arguments: [String]) -> String {
        let promptFlags: Set<String> = ["-p", "--print", "--prompt", "--single"]
        let omitValueFlags: Set<String> = ["--json-schema"]
        var redacted: [String] = []
        var index = 0
        while index < arguments.count {
            let argument = arguments[index]
            if promptFlags.contains(argument), index + 1 < arguments.count {
                redacted.append(argument)
                redacted.append("<prompt redacted>")
                index += 2
                continue
            }
            if omitValueFlags.contains(argument), index + 1 < arguments.count {
                redacted.append(argument)
                redacted.append("<schema omitted>")
                index += 2
                continue
            }
            // Positional prompt (e.g. codex exec … <prompt>) or any oversized value.
            if !argument.hasPrefix("-"), argument.count > 120 {
                redacted.append("<prompt redacted>")
                index += 1
                continue
            }
            redacted.append(argument)
            index += 1
        }
        return redacted.joined(separator: " ")
    }

    private func modelFlag(for provider: AIProvider, modelID: String) -> [String] {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "default" else { return [] }
        switch provider {
        case .codex, .claude, .grok, .gemini, .agy:
            return ["--model", trimmed]
        }
    }

    static func resolveMessage(
        provider: AIProvider,
        result: ProcessResult,
        outputFile: URL?
    ) throws -> String {
        guard result.exitCode == 0 else {
            let combined = (result.stderr + "\n" + result.stdout)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if looksUnauthenticated(combined) {
                throw ProviderGenerationError.authenticationExpired(provider)
            }
            let detail = combined.isEmpty
                ? "No diagnostic output was produced. Verify the CLI is authenticated and the selected model is available."
                : String(combined.suffix(1200))
            throw ProviderGenerationError.invalidResponse(
                "\(provider.displayName) exited with code \(result.exitCode) before producing a manifest. "
                    + "Review the provider output and verify authentication/model settings.\n\(detail)"
            )
        }

        if let outputFile,
           FileManager.default.fileExists(atPath: outputFile.path),
           let data = try? Data(contentsOf: outputFile),
           let text = String(data: data, encoding: .utf8),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let payload = ManifestGenerationSupport.extractMessagePayload(from: text) {
                return payload
            }
            return text
        }

        if let payload = ManifestGenerationSupport.extractMessagePayload(from: result.stdout) {
            return payload
        }

        if let payload = ManifestGenerationSupport.extractMessagePayload(from: result.stderr) {
            return payload
        }

        let combined = (result.stdout + "\n" + result.stderr)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if looksUnauthenticated(combined) {
            throw ProviderGenerationError.authenticationExpired(provider)
        }
        throw ProviderGenerationError.invalidResponse(
            "\(provider.displayName) finished without a usable JSON manifest.\n\(combined.suffix(1200))"
        )
    }

    private static func looksUnauthenticated(_ output: String) -> Bool {
        let lower = output.lowercased()
        let negativeSignals = [
            "not logged in",
            "not authenticated",
            "logged out",
            "please login",
            "please log in",
            "run codex login",
            "run claude auth login",
            "run grok login",
            "no auth",
            "unauthenticated",
            "missing credentials",
            "failed to authenticate",
            "token expired",
            "token has been revoked",
            "re-authentication required",
            "refresh token rejected",
            "invalid_grant",
            "\"loggedin\": false",
            "\"loggedin\":false",
            "loggedin=false",
            "ineligibletier",
            "no longer supported for gemini",
            "migrate to the antigravity",
            "error authenticating"
        ]
        if negativeSignals.contains(where: { lower.contains($0) }) {
            return true
        }
        let positiveSignals = [
            "logged in", "authenticated", "chatgpt", "api key",
            "\"loggedin\": true", "\"loggedin\":true"
        ]
        if positiveSignals.contains(where: { lower.contains($0) }) {
            return false
        }
        return false
    }

    private func readGeminiAuth(environment: [String: String]) -> AuthProbe {
        let configDirectory = geminiConfigDirectory(environment: environment)
        let configuredSelection = Self.geminiConfiguredAuthSelection(in: configDirectory)
        let oauthConfigured = Self.isNonEmptyJSONObject(
            at: configDirectory.appendingPathComponent("oauth_creds.json")
        )

        let effectiveAuthType: GeminiAuthType?
        switch configuredSelection {
        case .supported(let authType):
            effectiveAuthType = authType
        case .unsupported:
            return AuthProbe(
                ok: false,
                summary: "Gemini's selected authentication type is unsupported or invalid."
            )
        case .none:
            // Mirrors Gemini CLI 0.42's getAuthTypeFromEnv precedence.
            if Self.environmentFlag("GOOGLE_GENAI_USE_GCA", in: environment) {
                effectiveAuthType = .oauth
            } else if Self.environmentFlag("GOOGLE_GENAI_USE_VERTEXAI", in: environment) {
                effectiveAuthType = .vertexAI
            } else if Self.hasEnvironmentValue("GEMINI_API_KEY", in: environment) {
                effectiveAuthType = .apiKey
            } else if Self.environmentFlag("CLOUD_SHELL", in: environment)
                        || Self.environmentFlag("GEMINI_CLI_USE_COMPUTE_ADC", in: environment) {
                effectiveAuthType = .computeADC
            } else {
                effectiveAuthType = nil
            }
        }

        switch effectiveAuthType {
        case .oauth:
            return oauthConfigured
                ? AuthProbe(ok: true, summary: "Authenticated with Google OAuth")
                : AuthProbe(ok: false, summary: "The selected Google OAuth session is missing — run `gemini` and sign in.")
        case .apiKey:
            return Self.hasEnvironmentValue("GEMINI_API_KEY", in: environment)
                ? AuthProbe(ok: true, summary: "Gemini API key configured")
                : AuthProbe(ok: false, summary: "The selected Gemini API key authentication is not configured.")
        case .vertexAI:
            return Self.geminiVertexEnvironmentIsConfigured(environment)
                ? AuthProbe(ok: true, summary: "Vertex AI credentials configured")
                : AuthProbe(ok: false, summary: "The selected Vertex AI authentication is incomplete.")
        case .computeADC:
            return AuthProbe(ok: true, summary: "Application Default Credentials configured")
        case nil:
            return AuthProbe(
                ok: false,
                summary: "Gemini authentication is not configured — sign in or configure a supported API, Vertex AI, or ADC credential."
            )
        }
    }

    private func geminiConfigDirectory(environment: [String: String]) -> URL {
        let rootPath = Self.environmentValue("GEMINI_CLI_HOME", in: environment)
            ?? Self.environmentValue("HOME", in: environment)
        guard let rootPath else {
            return homeDirectoryURL.appendingPathComponent(".gemini", isDirectory: true)
        }

        let expanded = (rootPath as NSString).expandingTildeInPath
        let rootURL: URL
        if (expanded as NSString).isAbsolutePath {
            rootURL = URL(fileURLWithPath: expanded, isDirectory: true)
        } else {
            rootURL = homeDirectoryURL.appendingPathComponent(expanded, isDirectory: true)
        }
        return rootURL.appendingPathComponent(".gemini", isDirectory: true)
    }

    private static func geminiConfiguredAuthSelection(
        in configDirectory: URL
    ) -> GeminiAuthSelection {
        let settingsURL = configDirectory.appendingPathComponent("settings.json")
        guard
            let data = try? Data(contentsOf: settingsURL),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let security = root["security"] as? [String: Any],
            let auth = security["auth"] as? [String: Any],
            let selectedType = auth["selectedType"] as? String
        else {
            return .none
        }
        guard let authType = GeminiAuthType(rawValue: selectedType) else {
            return .unsupported
        }
        return .supported(authType)
    }

    private static func geminiVertexEnvironmentIsConfigured(
        _ environment: [String: String]
    ) -> Bool {
        if hasEnvironmentValue("GOOGLE_API_KEY", in: environment) {
            return true
        }
        let hasProject = hasEnvironmentValue("GOOGLE_CLOUD_PROJECT", in: environment)
        let hasLocation = hasEnvironmentValue("GOOGLE_CLOUD_LOCATION", in: environment)
        if let credentialsPath = environmentValue(
            "GOOGLE_APPLICATION_CREDENTIALS",
            in: environment
        ) {
            let expandedPath = (credentialsPath as NSString).expandingTildeInPath
            var isDirectory: ObjCBool = false
            guard (expandedPath as NSString).isAbsolutePath,
                  FileManager.default.fileExists(
                    atPath: expandedPath,
                    isDirectory: &isDirectory
                  ),
                  !isDirectory.boolValue,
                  FileManager.default.isReadableFile(atPath: expandedPath) else {
                return false
            }
        }
        return hasProject && hasLocation
    }

    private static func isNonEmptyJSONObject(at url: URL) -> Bool {
        guard
            let data = try? Data(contentsOf: url),
            !data.isEmpty,
            let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return false
        }
        return !object.isEmpty
    }

    private static func environmentFlag(
        _ key: String,
        in environment: [String: String]
    ) -> Bool {
        environmentValue(key, in: environment)?.lowercased() == "true"
    }

    private static func hasEnvironmentValue(
        _ key: String,
        in environment: [String: String]
    ) -> Bool {
        environmentValue(key, in: environment) != nil
    }

    private static func environmentValue(
        _ key: String,
        in environment: [String: String]
    ) -> String? {
        guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
              !value.isEmpty else {
            return nil
        }
        return value
    }
}
