import Foundation

/// Discovers concrete model IDs available to each local CLI.
/// Prefers on-disk CLI caches (no network), with small built-in fallbacks.
enum ModelCatalog {
    /// Models available for a provider. Ready providers get cache-backed lists;
    /// others still receive fallbacks so the UI can show options when possible.
    static func models(for provider: AIProvider) -> [AIModelOption] {
        models(
            for: provider,
            homeDirectoryURL: URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
        )
    }

    /// Injectable home directory keeps cache/config compatibility covered by
    /// deterministic tests as provider CLIs evolve their local schemas.
    static func models(for provider: AIProvider, homeDirectoryURL: URL) -> [AIModelOption] {
        let discovered: [AIModelOption]
        switch provider {
        case .grok:
            discovered = readGrokModels(homeDirectoryURL: homeDirectoryURL)
        case .codex:
            discovered = readCodexModels(homeDirectoryURL: homeDirectoryURL)
        case .claude:
            discovered = readClaudeModels(homeDirectoryURL: homeDirectoryURL)
        case .gemini:
            discovered = readGeminiModels(homeDirectoryURL: homeDirectoryURL)
        case .agy:
            discovered = readAgyModels(homeDirectoryURL: homeDirectoryURL)
        }

        if discovered.isEmpty {
            return fallbackModels(for: provider)
        }
        return discovered
    }

    static func allModels(readyProviders: [AIProvider]? = nil) -> [AIModelOption] {
        let providers = readyProviders ?? AIProvider.allCases
        return providers.flatMap { models(for: $0) }
    }

    // MARK: - Grok (`~/.grok/models_cache.json` or `grok models` text)

    private static func readGrokModels(homeDirectoryURL: URL) -> [AIModelOption] {
        let url = homeURL(".grok/models_cache.json", in: homeDirectoryURL)
        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = root["models"] as? [String: Any]
        else {
            return []
        }

        var options: [AIModelOption] = []
        for (key, value) in models {
            guard let entry = value as? [String: Any] else { continue }
            let info = entry["info"] as? [String: Any]
            let modelID = (info?["id"] as? String)
                ?? (info?["model"] as? String)
                ?? key
            if info?["hidden"] as? Bool == true { continue }
            let name = (info?["name"] as? String) ?? (info?["system_prompt_label"] as? String)
            let description = info?["description"] as? String
            options.append(
                AIModelOption(
                    provider: .grok,
                    modelID: modelID,
                    displayName: name,
                    description: description,
                    isDefault: false
                )
            )
        }

        // Mark default from cache / config if present.
        if let defaultID = readGrokDefaultModelID(homeDirectoryURL: homeDirectoryURL) {
            options = options.map {
                var copy = $0
                copy.isDefault = ($0.modelID == defaultID)
                return copy
            }
            if !options.contains(where: { $0.modelID == defaultID }) {
                options.insert(
                    AIModelOption(provider: .grok, modelID: defaultID, isDefault: true),
                    at: 0
                )
            }
        } else if let first = options.indices.first {
            options[first].isDefault = true
        }

        return options.sorted { $0.displayName.localizedCaseInsensitiveCompare($1.displayName) == .orderedAscending }
    }

    private static func readGrokDefaultModelID(homeDirectoryURL: URL) -> String? {
        // Prefer config.toml [models] default = "…"
        if let config = try? String(
            contentsOf: homeURL(".grok/config.toml", in: homeDirectoryURL),
            encoding: .utf8
        ) {
            if let match = config.range(of: #"(?m)^\s*default\s*=\s*"([^"]+)""#, options: .regularExpression) {
                let line = String(config[match])
                if let q1 = line.firstIndex(of: "\""),
                   let q2 = line.lastIndex(of: "\""),
                   q1 < q2 {
                    let id = String(line[line.index(after: q1)..<q2])
                    if !id.isEmpty { return id }
                }
            }
        }
        return nil
    }

    // MARK: - Codex (`~/.codex/models_cache.json`)

    private static func readCodexModels(homeDirectoryURL: URL) -> [AIModelOption] {
        let url = homeURL(".codex/models_cache.json", in: homeDirectoryURL)
        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = root["models"] as? [[String: Any]]
        else {
            return codexConfigDefault(homeDirectoryURL: homeDirectoryURL).map { [$0] } ?? []
        }

        var options: [AIModelOption] = []
        for entry in models {
            let visibility = (entry["visibility"] as? String) ?? "list"
            // Only surface models intended for the picker.
            guard visibility == "list" || visibility == "default" else { continue }
            guard let slug = entry["slug"] as? String, !slug.isEmpty else { continue }
            let name = entry["display_name"] as? String
            let description = entry["description"] as? String
            options.append(
                AIModelOption(
                    provider: .codex,
                    modelID: slug,
                    displayName: name,
                    description: description,
                    isDefault: false
                )
            )
        }

        if let defaultID = codexConfiguredModelID(homeDirectoryURL: homeDirectoryURL) {
            options = options.map {
                var copy = $0
                copy.isDefault = ($0.modelID == defaultID)
                return copy
            }
            if !options.contains(where: { $0.modelID == defaultID }) {
                options.insert(
                    AIModelOption(provider: .codex, modelID: defaultID, isDefault: true),
                    at: 0
                )
            }
        } else if let first = options.indices.first {
            options[first].isDefault = true
        }

        return options
    }

    private static func codexConfiguredModelID(homeDirectoryURL: URL) -> String? {
        guard let config = try? String(
            contentsOf: homeURL(".codex/config.toml", in: homeDirectoryURL),
            encoding: .utf8
        ) else {
            return nil
        }
        // model = "gpt-5.6-sol"
        guard let match = config.range(of: #"(?m)^\s*model\s*=\s*"([^"]+)""#, options: .regularExpression) else {
            return nil
        }
        let line = String(config[match])
        guard let q1 = line.firstIndex(of: "\""),
              let q2 = line.lastIndex(of: "\""),
              q1 < q2 else { return nil }
        let id = String(line[line.index(after: q1)..<q2])
        return id.isEmpty ? nil : id
    }

    private static func codexConfigDefault(homeDirectoryURL: URL) -> AIModelOption? {
        guard let id = codexConfiguredModelID(homeDirectoryURL: homeDirectoryURL) else { return nil }
        return AIModelOption(provider: .codex, modelID: id, isDefault: true)
    }

    // MARK: - Claude (settings + documented aliases)

    private static func readClaudeModels(homeDirectoryURL: URL) -> [AIModelOption] {
        var options = fallbackModels(for: .claude)
        if let configured = claudeConfiguredModelID(homeDirectoryURL: homeDirectoryURL) {
            if let idx = options.firstIndex(where: { $0.modelID == configured }) {
                options = options.map {
                    var copy = $0
                    copy.isDefault = ($0.modelID == configured)
                    return copy
                }
                _ = idx
            } else {
                options.insert(
                    AIModelOption(
                        provider: .claude,
                        modelID: configured,
                        displayName: configured,
                        description: "From Claude settings",
                        isDefault: true
                    ),
                    at: 0
                )
                options = options.enumerated().map { i, m in
                    var copy = m
                    if i > 0 { copy.isDefault = false }
                    return copy
                }
            }
        }
        return options
    }

    private static func claudeConfiguredModelID(homeDirectoryURL: URL) -> String? {
        let url = homeURL(".claude/settings.json", in: homeDirectoryURL)
        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let model = root["model"] as? String,
            !model.isEmpty
        else {
            return nil
        }
        return model
    }

    // MARK: - Gemini (`~/.gemini/settings.json`)

    private static func readGeminiModels(homeDirectoryURL: URL) -> [AIModelOption] {
        var options = fallbackModels(for: .gemini)
        if let configured = geminiConfiguredModelID(homeDirectoryURL: homeDirectoryURL) {
            if let idx = options.firstIndex(where: { $0.modelID == configured }) {
                options = options.enumerated().map { i, m in
                    var copy = m
                    copy.isDefault = (i == idx)
                    return copy
                }
            } else {
                options.insert(
                    AIModelOption(
                        provider: .gemini,
                        modelID: configured,
                        displayName: configured,
                        description: "From Gemini settings",
                        isDefault: true
                    ),
                    at: 0
                )
                options = options.enumerated().map { i, m in
                    var copy = m
                    if i > 0 { copy.isDefault = false }
                    return copy
                }
            }
        }
        return options
    }

    private static func geminiConfiguredModelID(homeDirectoryURL: URL) -> String? {
        let url = homeURL(".gemini/settings.json", in: homeDirectoryURL)
        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return nil
        }
        if let model = root["model"] as? String, !model.isEmpty {
            return model
        }
        if let modelObj = root["model"] as? [String: Any],
           let name = modelObj["name"] as? String,
           !name.isEmpty {
            return name
        }
        return nil
    }

    // MARK: - Antigravity / agy (`~/.gemini/antigravity-cli/settings.json`)

    private static func readAgyModels(homeDirectoryURL: URL) -> [AIModelOption] {
        var options = fallbackModels(for: .agy)
        if let configured = agyConfiguredModelID(homeDirectoryURL: homeDirectoryURL) {
            // Settings may store either a slug (`gemini-3.1-pro-high`) or a display
            // label (`Claude Opus 4.6 (Thinking)`). Prefer exact modelID match, then
            // case-insensitive displayName match.
            if let idx = options.firstIndex(where: {
                $0.modelID == configured
                    || $0.displayName.caseInsensitiveCompare(configured) == .orderedSame
            }) {
                options = options.enumerated().map { i, m in
                    var copy = m
                    copy.isDefault = (i == idx)
                    return copy
                }
            } else {
                options.insert(
                    AIModelOption(
                        provider: .agy,
                        modelID: configured,
                        displayName: configured,
                        description: "From Antigravity settings",
                        isDefault: true
                    ),
                    at: 0
                )
                options = options.enumerated().map { i, m in
                    var copy = m
                    if i > 0 { copy.isDefault = false }
                    return copy
                }
            }
        }
        return options
    }

    private static func agyConfiguredModelID(homeDirectoryURL: URL) -> String? {
        let url = homeURL(".gemini/antigravity-cli/settings.json", in: homeDirectoryURL)
        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let model = root["model"] as? String,
            !model.isEmpty
        else {
            return nil
        }
        return model
    }

    // MARK: - Fallbacks

    private static func fallbackModels(for provider: AIProvider) -> [AIModelOption] {
        switch provider {
        case .grok:
            return [
                AIModelOption(
                    provider: .grok,
                    modelID: "grok-4.5",
                    displayName: "Grok 4.5",
                    description: "Default Grok Build model",
                    isDefault: true
                )
            ]
        case .codex:
            return [
                AIModelOption(
                    provider: .codex,
                    modelID: "gpt-5.6-sol",
                    displayName: "GPT-5.6-Sol",
                    description: "Latest frontier agentic coding model",
                    isDefault: true
                ),
                AIModelOption(
                    provider: .codex,
                    modelID: "gpt-5.6-terra",
                    displayName: "GPT-5.6-Terra",
                    description: "Balanced everyday coding model"
                ),
                AIModelOption(
                    provider: .codex,
                    modelID: "gpt-5.6-luna",
                    displayName: "GPT-5.6-Luna",
                    description: "Fast and affordable coding model"
                )
            ]
        case .claude:
            // Documented aliases from `claude --help`.
            return [
                AIModelOption(
                    provider: .claude,
                    modelID: "sonnet",
                    displayName: "Sonnet",
                    description: "Balanced Claude model alias",
                    isDefault: true
                ),
                AIModelOption(
                    provider: .claude,
                    modelID: "opus",
                    displayName: "Opus",
                    description: "Highest-capability Claude model alias"
                ),
                AIModelOption(
                    provider: .claude,
                    modelID: "fable",
                    displayName: "Fable",
                    description: "Latest Claude model alias"
                )
            ]
        case .gemini:
            // Common Gemini CLI model IDs; settings can override the default.
            return [
                AIModelOption(
                    provider: .gemini,
                    modelID: "gemini-3.1-pro-preview",
                    displayName: "Gemini 3.1 Pro",
                    description: "Default Gemini CLI model",
                    isDefault: true
                ),
                AIModelOption(
                    provider: .gemini,
                    modelID: "gemini-3-flash-preview",
                    displayName: "Gemini 3 Flash",
                    description: "Fast Gemini model"
                ),
                AIModelOption(
                    provider: .gemini,
                    modelID: "gemini-2.5-pro",
                    displayName: "Gemini 2.5 Pro",
                    description: "Stable Gemini Pro model"
                )
            ]
        case .agy:
            // Documented IDs from `agy models` (Antigravity CLI).
            return [
                AIModelOption(
                    provider: .agy,
                    modelID: "gemini-3.1-pro-high",
                    displayName: "Gemini 3.1 Pro (High)",
                    description: "Default Antigravity model",
                    isDefault: true
                ),
                AIModelOption(
                    provider: .agy,
                    modelID: "gemini-3.6-flash-medium",
                    displayName: "Gemini 3.6 Flash (Medium)",
                    description: "Balanced Flash model"
                ),
                AIModelOption(
                    provider: .agy,
                    modelID: "claude-sonnet-4-6",
                    displayName: "Claude Sonnet 4.6 (Thinking)",
                    description: "Claude via Antigravity"
                ),
                AIModelOption(
                    provider: .agy,
                    modelID: "claude-opus-4-6-thinking",
                    displayName: "Claude Opus 4.6 (Thinking)",
                    description: "Highest-capability Claude via Antigravity"
                )
            ]
        }
    }

    private static func homeURL(_ relative: String, in root: URL) -> URL {
        root.appendingPathComponent(relative)
    }
}
