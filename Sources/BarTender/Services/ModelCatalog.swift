import Foundation

/// Discovers concrete model IDs available to each local CLI.
/// Prefers on-disk CLI caches (no network), with small built-in fallbacks.
enum ModelCatalog {
    /// Models available for a provider. Ready providers get cache-backed lists;
    /// others still receive fallbacks so the UI can show options when possible.
    static func models(for provider: AIProvider) -> [AIModelOption] {
        let discovered: [AIModelOption]
        switch provider {
        case .grok:
            discovered = readGrokModels()
        case .codex:
            discovered = readCodexModels()
        case .claude:
            discovered = readClaudeModels()
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

    private static func readGrokModels() -> [AIModelOption] {
        let url = homeURL(".grok/models_cache.json")
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
        if let defaultID = readGrokDefaultModelID() {
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

    private static func readGrokDefaultModelID() -> String? {
        // Prefer config.toml [models] default = "…"
        if let config = try? String(contentsOf: homeURL(".grok/config.toml"), encoding: .utf8) {
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

    private static func readCodexModels() -> [AIModelOption] {
        let url = homeURL(".codex/models_cache.json")
        guard
            let data = try? Data(contentsOf: url),
            let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
            let models = root["models"] as? [[String: Any]]
        else {
            return codexConfigDefault().map { [$0] } ?? []
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

        if let defaultID = codexConfiguredModelID() {
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

    private static func codexConfiguredModelID() -> String? {
        guard let config = try? String(contentsOf: homeURL(".codex/config.toml"), encoding: .utf8) else {
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

    private static func codexConfigDefault() -> AIModelOption? {
        guard let id = codexConfiguredModelID() else { return nil }
        return AIModelOption(provider: .codex, modelID: id, isDefault: true)
    }

    // MARK: - Claude (settings + documented aliases)

    private static func readClaudeModels() -> [AIModelOption] {
        var options = fallbackModels(for: .claude)
        if let configured = claudeConfiguredModelID() {
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

    private static func claudeConfiguredModelID() -> String? {
        let url = homeURL(".claude/settings.json")
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
                    modelID: "haiku",
                    displayName: "Haiku",
                    description: "Fast Claude model alias"
                ),
                AIModelOption(
                    provider: .claude,
                    modelID: "fable",
                    displayName: "Fable",
                    description: "Latest Claude model alias"
                )
            ]
        }
    }

    private static func homeURL(_ relative: String) -> URL {
        URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent(relative)
    }
}
