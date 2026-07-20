import Foundation

/// Discovers and invokes local AI CLIs (Codex, Claude, Grok).
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
        .grok: .checking
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
            let preferred = enabledProviders.contains(provider)
                ? provider
                : (enabledProviders.first ?? provider)
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
           let fallback = enabledProviders.first {
            selectProvider(fallback)
        }

        // Drop selected model if its provider is now off.
        if !enabledProviders.contains(selectedModel.provider),
           let fallback = selectableModels.first ?? enabledProviders.first.map({ preferredModel(for: $0) }) {
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
        // Probe sequentially on the main actor so ProcessRunner hops stay simple.
        for provider in AIProvider.allCases {
            statuses[provider] = await probe(provider, environment: environment)
        }

        refreshModelCatalog()

        // Prefer keeping the user's selection if ready; otherwise fall back to first ready provider/model.
        if !isProviderEnabled(selectedProvider) || !availability.isReady,
           let fallback = readyProviders.first {
            selectProvider(fallback)
            AppLog.codex.info("Selected provider fell back to \(fallback.rawValue, privacy: .public)")
        } else if !selectableModels.contains(where: { $0.id == selectedModel.id }) {
            selectedModel = preferredModel(for: selectedProvider)
        }
    }

    func refreshModelCatalog() {
        availableModels = AIProvider.allCases.flatMap(modelProvider)
        AppLog.codex.info("Model catalog loaded (\(self.availableModels.count, privacy: .public) models)")
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
        Task {
            await generationRunner?.cancel()
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
        onLog(.system, "Args: \(invocation.arguments.joined(separator: " "))")
        onLog(.system, existingTool.map { "Mode: Revising \($0.name) in place" } ?? "Mode: Creating a new tool")
        if iterationFeedback != nil {
            onLog(.system, "Feedback: Retrying with validator or first-run diagnostics")
        }
        onLog(.system, "Prompt: \(trimmed)")

        let localRunner = ProcessRunner()
        generationRunner = localRunner

        guard !generationCancellationRequested else {
            generationRunner = nil
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
            generationTask = nil
            generationRunner = nil
            generationCancellationRequested = false
        }
        do {
            let manifest = try await task.value
            guard !generationCancellationRequested else {
                throw ProviderGenerationError.cancelled
            }
            return manifest
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
            AppLog.codex.error("\(provider.rawValue, privacy: .public) CLI not found on PATH")
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
            AppLog.codex.info("\(provider.rawValue, privacy: .public) ready at \(path, privacy: .public) (\(version, privacy: .public))")
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

    private func readVersion(provider: AIProvider, path: String, env: [String: String]) async throws -> String {
        // Documented version flags:
        // codex --version | claude --version | grok --version / grok version
        let args: [String]
        switch provider {
        case .codex, .claude, .grok:
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
        // All three CLIs document `-m` / `--model <MODEL>`.
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
        }
    }

    private func modelFlag(for provider: AIProvider, modelID: String) -> [String] {
        let trimmed = modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, trimmed != "default" else { return [] }
        switch provider {
        case .codex, .claude, .grok:
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
            "loggedin=false"
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
}

/// Compatibility alias so existing `@EnvironmentObject private var codex` call sites keep compiling
/// while views migrate to `providers`.
typealias CodexCLIService = AIProviderService
