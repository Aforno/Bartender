import Foundation

/// A concrete model exposed by a local CLI provider (not the provider itself).
struct AIModelOption: Identifiable, Hashable, Equatable, Sendable, Codable {
    /// Stable selection key: `provider/modelID`.
    var id: String { "\(provider.rawValue)/\(modelID)" }

    var provider: AIProvider
    /// Value passed to the CLI (`-m` / `--model`).
    var modelID: String
    var displayName: String
    var description: String?
    var isDefault: Bool

    init(
        provider: AIProvider,
        modelID: String,
        displayName: String? = nil,
        description: String? = nil,
        isDefault: Bool = false
    ) {
        self.provider = provider
        self.modelID = modelID
        self.displayName = displayName ?? Self.prettyName(from: modelID)
        self.description = description
        self.isDefault = isDefault
    }

    /// Short label suitable for the composer chip (e.g. "Grok 4.5", "GPT-5.6-Sol").
    var shortLabel: String {
        displayName
    }

    private static func prettyName(from modelID: String) -> String {
        modelID
            .replacingOccurrences(of: "-", with: " ")
            .split(separator: " ")
            .map { part -> String in
                let s = String(part)
                if s.allSatisfy(\.isNumber) || s.contains(".") { return s }
                return s.prefix(1).uppercased() + s.dropFirst()
            }
            .joined(separator: " ")
    }
}
