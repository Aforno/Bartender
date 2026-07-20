import Foundation

struct ProviderLogLine: Identifiable, Equatable, Sendable {
    enum Stream: String, Sendable {
        case stdout
        case stderr
        case system
    }

    let id: UUID
    let date: Date
    let stream: Stream
    let text: String

    init(id: UUID = UUID(), date: Date = .now, stream: Stream, text: String) {
        self.id = id
        self.date = date
        self.stream = stream
        self.text = text
    }
}

typealias CodexLogLine = ProviderLogLine

enum GenerationPhase: String, Equatable, Sendable {
    case idle
    case preparing
    case running
    case parsing
    case succeeded
    case failed
    case cancelled

    func displayName(for provider: AIProvider? = nil) -> String {
        switch self {
        case .idle: return "Idle"
        case .preparing: return "Designing your tool"
        case .running:
            if let provider {
                return "\(provider.displayName) is writing the tool"
            }
            return "Writing generated tool"
        case .parsing: return "Installing in the menu bar"
        case .succeeded: return "Installed"
        case .failed: return "Failed"
        case .cancelled: return "Cancelled"
        }
    }

    /// Convenience for views that still read `.displayName`.
    var displayName: String { displayName(for: nil) }

    var isActive: Bool {
        switch self {
        case .preparing, .running, .parsing:
            return true
        default:
            return false
        }
    }
}

@MainActor
final class GenerationSession: ObservableObject, Identifiable {
    static let maximumLogLines = 2_000

    let id = UUID()
    let prompt: String
    let provider: AIProvider
    let targetAppletID: UUID?
    let targetAppletName: String?
    let startedAt = Date()

    @Published var phase: GenerationPhase = .preparing
    @Published var logs: [ProviderLogLine] = []
    @Published var resultManifest: AppletManifest?
    @Published var errorMessage: String?
    @Published var finishedAt: Date?

    init(
        prompt: String,
        provider: AIProvider,
        targetAppletID: UUID? = nil,
        targetAppletName: String? = nil
    ) {
        self.prompt = prompt
        self.provider = provider
        self.targetAppletID = targetAppletID
        self.targetAppletName = targetAppletName
    }

    var isRevision: Bool { targetAppletID != nil }

    func append(stream: ProviderLogLine.Stream, _ text: String) {
        let chunks = text.split(whereSeparator: \.isNewline)
        guard !chunks.isEmpty else {
            if !text.isEmpty {
                logs.append(ProviderLogLine(stream: stream, text: text))
                trimLogsIfNeeded()
            }
            return
        }
        for chunk in chunks {
            let line = String(chunk).trimmingCharacters(in: .whitespaces)
            guard !line.isEmpty else { continue }
            logs.append(ProviderLogLine(stream: stream, text: line))
        }
        trimLogsIfNeeded()
    }

    private func trimLogsIfNeeded() {
        let overflow = logs.count - Self.maximumLogLines
        if overflow > 0 {
            logs.removeFirst(overflow)
        }
    }
}

enum ProviderGenerationError: LocalizedError {
    case notReady(AIProvider)
    case emptyPrompt
    case cancelled
    case authenticationExpired(AIProvider)
    case invalidResponse(String)
    case missingCommandDependency(String)
    case noProvidersReady

    var errorDescription: String? {
        switch self {
        case .notReady(let provider):
            return "\(provider.displayName) CLI is not ready. Resolve the setup issue or pick another provider."
        case .emptyPrompt:
            return "Describe the menu bar utility you want to create."
        case .cancelled:
            return "Generation was cancelled."
        case .authenticationExpired(let provider):
            return "\(provider.displayName) rejected the saved authentication. \(provider.loginHint) Then recheck providers and try again."
        case .invalidResponse(let detail):
            return detail
        case .missingCommandDependency(let tool):
            return "The generated tool runs `\(tool)`, which is not installed on this Mac. "
                + "Install it (for example `brew install \(tool)`) and generate again, "
                + "or rephrase your request to use tools that ship with macOS."
        case .noProvidersReady:
            return "No AI provider CLI is ready. Install and sign in to Codex, Claude, or Grok."
        }
    }
}

typealias CodexGenerationError = ProviderGenerationError
