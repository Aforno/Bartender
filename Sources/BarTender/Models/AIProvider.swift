import Foundation

/// Local CLI backends that can generate applet manifests.
enum AIProvider: String, CaseIterable, Identifiable, Codable, Sendable {
    case codex
    case claude
    case grok

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .codex: return "Codex"
        case .claude: return "Claude"
        case .grok: return "Grok"
        }
    }

    var executableName: String {
        switch self {
        case .codex: return "codex"
        case .claude: return "claude"
        case .grok: return "grok"
        }
    }

    var iconResourceName: String {
        switch self {
        case .codex: return "chatgpt"
        case .claude: return "claude"
        case .grok: return "grok"
        }
    }

    var installHint: String {
        switch self {
        case .codex:
            return "Install the Codex CLI and ensure `codex` is on your shell PATH."
        case .claude:
            return "Install Claude Code and ensure `claude` is on your shell PATH."
        case .grok:
            return "Install the Grok CLI and ensure `grok` is on your shell PATH."
        }
    }

    var loginHint: String {
        switch self {
        case .codex:
            return "Run `codex login` in Terminal, complete authentication, then recheck."
        case .claude:
            return "Run `claude auth login` in Terminal, complete authentication, then recheck."
        case .grok:
            return "Run `grok login` in Terminal, complete authentication, then recheck."
        }
    }

    var loginCommand: String {
        switch self {
        case .codex: return "codex login"
        case .claude: return "claude auth login"
        case .grok: return "grok login"
        }
    }
}

enum ProviderAvailability: Equatable, Sendable {
    case checking
    case ready(ProviderInstallation)
    case unavailable(ProviderSetupIssue)

    var isReady: Bool {
        if case .ready = self { return true }
        return false
    }

    var installation: ProviderInstallation? {
        if case .ready(let install) = self { return install }
        return nil
    }

    var issue: ProviderSetupIssue? {
        if case .unavailable(let issue) = self { return issue }
        return nil
    }
}

struct ProviderInstallation: Equatable, Sendable {
    var provider: AIProvider
    var executablePath: String
    var version: String
    var authSummary: String
}

enum ProviderSetupIssue: Equatable, Sendable {
    case notFound
    case notAuthenticated(String)
    case versionCheckFailed(String)
    case loginCheckFailed(String)

    func title(for provider: AIProvider) -> String {
        switch self {
        case .notFound:
            return "\(provider.displayName) CLI not found"
        case .notAuthenticated:
            return "\(provider.displayName) is not authenticated"
        case .versionCheckFailed:
            return "Could not read \(provider.displayName) version"
        case .loginCheckFailed:
            return "Could not verify \(provider.displayName) login"
        }
    }

    func message(for provider: AIProvider) -> String {
        switch self {
        case .notFound:
            return """
            Bar Tender uses the \(provider.displayName) CLI already installed on your Mac. \
            \(provider.installHint)
            """
        case .notAuthenticated(let detail):
            return """
            \(provider.displayName) is installed but not signed in. \(provider.loginHint)

            \(detail)
            """
        case .versionCheckFailed(let detail):
            return "Bar Tender found a `\(provider.executableName)` binary but could not read its version.\n\n\(detail)"
        case .loginCheckFailed(let detail):
            return "Bar Tender could not verify \(provider.displayName) authentication.\n\n\(detail)"
        }
    }

    func recoverySuggestion(for provider: AIProvider) -> String {
        switch self {
        case .notFound:
            return provider.installHint
        case .notAuthenticated:
            return provider.loginHint
        case .versionCheckFailed, .loginCheckFailed:
            return "Confirm the \(provider.displayName) CLI runs correctly in Terminal, then recheck from Bar Tender."
        }
    }
}

// Backward-compatible aliases used by older view names during the multi-provider migration.
typealias CodexAvailability = ProviderAvailability
typealias CodexInstallation = ProviderInstallation
typealias CodexSetupIssue = ProviderSetupIssue
