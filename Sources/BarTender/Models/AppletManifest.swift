import Foundation

struct AppletManifest: Identifiable, Codable, Equatable, Sendable, Hashable {
    var id: UUID
    var name: String
    var iconSystemName: String
    var kind: AppletKind
    var titleTemplate: String
    var refreshIntervalSeconds: Double?
    var enabled: Bool
    var createdAt: Date
    var updatedAt: Date
    var sourcePrompt: String
    var config: AppletConfig
    var notifyOnComplete: Bool
    var notifyOnFailure: Bool

    init(
        id: UUID = UUID(),
        name: String,
        iconSystemName: String,
        kind: AppletKind,
        titleTemplate: String,
        refreshIntervalSeconds: Double? = nil,
        enabled: Bool = true,
        createdAt: Date = .now,
        updatedAt: Date = .now,
        sourcePrompt: String = "",
        config: AppletConfig,
        notifyOnComplete: Bool = false,
        notifyOnFailure: Bool = false
    ) {
        self.id = id
        self.name = name
        self.iconSystemName = iconSystemName
        self.kind = kind
        self.titleTemplate = titleTemplate
        self.refreshIntervalSeconds = refreshIntervalSeconds
        self.enabled = enabled
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.sourcePrompt = sourcePrompt
        self.config = config
        self.notifyOnComplete = notifyOnComplete
        self.notifyOnFailure = notifyOnFailure
    }
}

struct AppletConfig: Codable, Equatable, Sendable, Hashable {
    var durationSeconds: Int?
    var autoRestart: Bool?
    var url: String?
    var expectedStatusCode: Int?
    var timeoutSeconds: Double?
    var host: String?
    var port: Int?
    var metrics: [SystemMetricKind]?
    var repositoryPath: String?
    var command: String?
    var workingDirectory: String?
    /// Complete, provider-generated zsh program for a one-shot custom menu bar tool.
    /// The program prints one `GeneratedToolOutput` JSON object to stdout.
    var generatedSource: String?

    static let empty = AppletConfig()
}

enum SystemMetricKind: String, Codable, CaseIterable, Sendable, Hashable {
    case cpu
    case memory

    var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .memory: return "Memory"
        }
    }
}

/// Payload returned by an AI provider (without app-managed fields).
struct CodexAppletDraft: Codable, Equatable, Sendable {
    var name: String
    var iconSystemName: String
    var kind: AppletKind
    var titleTemplate: String
    var refreshIntervalSeconds: Double?
    var notifyOnComplete: Bool?
    var notifyOnFailure: Bool?
    var config: AppletConfig
}

enum ManifestLimits {
    static let nameLength = 60
    static let iconLength = 80
    static let titleLength = 80
    static let urlLength = 2048
    static let hostLength = 255
    static let pathLength = 1024
    static let commandLength = 2000
    static let generatedSourceLength = 16_000
    static let duration = 1...86400
    static let refreshInterval = 1.0...3600.0
    static let expectedStatusCode = 100...599
    static let timeout = 0.5...120.0
    static let port = 1...65535
}

enum ManifestValidationError: LocalizedError, Equatable {
    case emptyName
    case emptyIcon
    case emptyTitleTemplate
    case valueTooLong(field: String, maximum: Int)
    case invalidRefreshInterval(Double)
    case missingDuration
    case invalidDuration
    case missingURL
    case invalidURL
    case invalidExpectedStatusCode
    case invalidTimeout
    case missingPort
    case invalidPort
    case missingHost
    case missingMetrics
    case duplicateMetrics
    case missingRepositoryPath
    case missingCommand
    case missingGeneratedSource
    case configMismatch(String)

    var errorDescription: String? {
        switch self {
        case .emptyName:
            return "Applet name is required."
        case .emptyIcon:
            return "Icon system name is required."
        case .emptyTitleTemplate:
            return "Title template is required."
        case .valueTooLong(let field, let maximum):
            return "\(field) must be at most \(maximum) characters."
        case .invalidRefreshInterval(let value):
            return "Refresh interval \(value)s is out of range (1…3600)."
        case .missingDuration:
            return "Timer/countdown applets require durationSeconds."
        case .invalidDuration:
            return "durationSeconds must be between 1 and 86400."
        case .missingURL:
            return "HTTP monitors require a URL."
        case .invalidURL:
            return "HTTP monitor URL must be a valid http:// or https:// URL with a host."
        case .invalidExpectedStatusCode:
            return "Expected HTTP status must be between 100 and 599."
        case .invalidTimeout:
            return "Timeout must be between 0.5 and 120 seconds."
        case .missingPort:
            return "Port monitors require a port."
        case .invalidPort:
            return "Port must be between 1 and 65535."
        case .missingHost:
            return "Port monitors require a host."
        case .missingMetrics:
            return "System metrics applets require at least one metric."
        case .duplicateMetrics:
            return "System metrics may not contain duplicate values."
        case .missingRepositoryPath:
            return "Git status applets require a repositoryPath."
        case .missingCommand:
            return "Shell command applets require a command."
        case .missingGeneratedSource:
            return "Generated tools require source code."
        case .configMismatch(let detail):
            return detail
        }
    }
}

enum ManifestValidator {
    static func validateDraft(_ draft: CodexAppletDraft) throws {
        let normalized = normalized(draft)
        try validateIdentity(
            name: normalized.name,
            iconSystemName: normalized.iconSystemName,
            titleTemplate: normalized.titleTemplate,
            refreshIntervalSeconds: normalized.refreshIntervalSeconds
        )
        try validateConfig(normalized.config, kind: normalized.kind)
    }

    static func validate(_ manifest: AppletManifest) throws {
        let normalized = normalized(manifest)
        try validateIdentity(
            name: normalized.name,
            iconSystemName: normalized.iconSystemName,
            titleTemplate: normalized.titleTemplate,
            refreshIntervalSeconds: normalized.refreshIntervalSeconds
        )
        try validateConfig(normalized.config, kind: normalized.kind)
    }

    static func normalizedAndValidated(_ manifest: AppletManifest) throws -> AppletManifest {
        let value = normalized(manifest)
        try validate(value)
        return value
    }

    static func normalized(_ manifest: AppletManifest) -> AppletManifest {
        var value = manifest
        value.name = trimmed(manifest.name)
        value.iconSystemName = trimmed(manifest.iconSystemName)
        value.titleTemplate = trimmed(manifest.titleTemplate)
        value.sourcePrompt = trimmed(manifest.sourcePrompt)
        value.config = normalized(manifest.config)
        return value
    }

    static func makeManifest(from draft: CodexAppletDraft, sourcePrompt: String) throws -> AppletManifest {
        let draft = normalized(draft)
        try validateDraft(draft)

        return AppletManifest(
            name: draft.name,
            iconSystemName: draft.iconSystemName,
            kind: draft.kind,
            titleTemplate: draft.titleTemplate,
            refreshIntervalSeconds: draft.refreshIntervalSeconds ?? draft.kind.defaultRefreshInterval,
            sourcePrompt: trimmed(sourcePrompt),
            config: draft.config,
            notifyOnComplete: draft.notifyOnComplete ?? (draft.kind == .timer || draft.kind == .countdown),
            notifyOnFailure: draft.notifyOnFailure ?? false
        )
    }

    private static func normalized(_ draft: CodexAppletDraft) -> CodexAppletDraft {
        CodexAppletDraft(
            name: trimmed(draft.name),
            iconSystemName: trimmed(draft.iconSystemName),
            kind: draft.kind,
            titleTemplate: trimmed(draft.titleTemplate),
            refreshIntervalSeconds: draft.refreshIntervalSeconds,
            notifyOnComplete: draft.notifyOnComplete,
            notifyOnFailure: draft.notifyOnFailure,
            config: normalized(draft.config)
        )
    }

    private static func normalized(_ config: AppletConfig) -> AppletConfig {
        var value = config
        value.url = trimmedOptional(config.url)
        value.host = trimmedOptional(config.host)
        value.repositoryPath = trimmedOptional(config.repositoryPath)
        value.command = trimmedOptional(config.command)
        value.workingDirectory = trimmedOptional(config.workingDirectory)
        value.generatedSource = trimmedOptional(config.generatedSource)
        return value
    }

    private static func validateIdentity(
        name: String,
        iconSystemName: String,
        titleTemplate: String,
        refreshIntervalSeconds: Double?
    ) throws {
        guard !name.isEmpty else { throw ManifestValidationError.emptyName }
        try requireMaximumLength(name, field: "Applet name", maximum: ManifestLimits.nameLength)

        guard !iconSystemName.isEmpty else { throw ManifestValidationError.emptyIcon }
        try requireMaximumLength(iconSystemName, field: "Icon system name", maximum: ManifestLimits.iconLength)

        guard !titleTemplate.isEmpty else { throw ManifestValidationError.emptyTitleTemplate }
        try requireMaximumLength(titleTemplate, field: "Title template", maximum: ManifestLimits.titleLength)

        if let interval = refreshIntervalSeconds, !ManifestLimits.refreshInterval.contains(interval) {
            throw ManifestValidationError.invalidRefreshInterval(interval)
        }
    }

    private static func validateConfig(_ config: AppletConfig, kind: AppletKind) throws {
        switch kind {
        case .generatedTool:
            try rejectUnexpected(
                config,
                allowed: [.timeoutSeconds, .workingDirectory, .generatedSource],
                kind: kind
            )
            guard let source = config.generatedSource else {
                throw ManifestValidationError.missingGeneratedSource
            }
            try requireMaximumLength(
                source,
                field: "Generated source",
                maximum: ManifestLimits.generatedSourceLength
            )
            guard source.hasPrefix("#!/bin/zsh") || source.hasPrefix("#!/bin/bash") else {
                throw ManifestValidationError.configMismatch(
                    "Generated source must begin with #!/bin/zsh or #!/bin/bash."
                )
            }
            guard !source.utf8.contains(0) else {
                throw ManifestValidationError.configMismatch("Generated source may not contain null bytes.")
            }
            try validateTimeout(config.timeoutSeconds)
            if let directory = config.workingDirectory {
                try requireMaximumLength(directory, field: "Working directory", maximum: ManifestLimits.pathLength)
            }

        case .timer, .countdown:
            try rejectUnexpected(config, allowed: [.durationSeconds, .autoRestart], kind: kind)
            guard let duration = config.durationSeconds else {
                throw ManifestValidationError.missingDuration
            }
            guard ManifestLimits.duration.contains(duration) else {
                throw ManifestValidationError.invalidDuration
            }

        case .httpMonitor:
            try rejectUnexpected(config, allowed: [.url, .expectedStatusCode, .timeoutSeconds], kind: kind)
            guard let urlString = config.url else {
                throw ManifestValidationError.missingURL
            }
            try requireMaximumLength(urlString, field: "URL", maximum: ManifestLimits.urlLength)
            guard let url = URL(string: urlString),
                  let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https",
                  let host = url.host,
                  !host.isEmpty else {
                throw ManifestValidationError.invalidURL
            }
            if let status = config.expectedStatusCode,
               !ManifestLimits.expectedStatusCode.contains(status) {
                throw ManifestValidationError.invalidExpectedStatusCode
            }
            try validateTimeout(config.timeoutSeconds)

        case .portMonitor:
            try rejectUnexpected(config, allowed: [.timeoutSeconds, .host, .port], kind: kind)
            guard let host = config.host else { throw ManifestValidationError.missingHost }
            try requireMaximumLength(host, field: "Host", maximum: ManifestLimits.hostLength)
            guard let port = config.port else { throw ManifestValidationError.missingPort }
            guard ManifestLimits.port.contains(port) else { throw ManifestValidationError.invalidPort }
            try validateTimeout(config.timeoutSeconds)

        case .systemMetrics:
            try rejectUnexpected(config, allowed: [.metrics], kind: kind)
            let metrics = config.metrics ?? []
            guard !metrics.isEmpty else { throw ManifestValidationError.missingMetrics }
            guard Set(metrics).count == metrics.count else { throw ManifestValidationError.duplicateMetrics }

        case .gitStatus:
            try rejectUnexpected(config, allowed: [.repositoryPath], kind: kind)
            guard let path = config.repositoryPath else {
                throw ManifestValidationError.missingRepositoryPath
            }
            try requireMaximumLength(path, field: "Repository path", maximum: ManifestLimits.pathLength)

        case .shellCommand:
            try rejectUnexpected(config, allowed: [.command, .workingDirectory], kind: kind)
            guard let command = config.command else { throw ManifestValidationError.missingCommand }
            try requireMaximumLength(command, field: "Command", maximum: ManifestLimits.commandLength)
            if let directory = config.workingDirectory {
                try requireMaximumLength(directory, field: "Working directory", maximum: ManifestLimits.pathLength)
            }
        }
    }

    private static func validateTimeout(_ timeout: Double?) throws {
        if let timeout, !ManifestLimits.timeout.contains(timeout) {
            throw ManifestValidationError.invalidTimeout
        }
    }

    private enum ConfigField: String, CaseIterable {
        case durationSeconds
        case autoRestart
        case url
        case expectedStatusCode
        case timeoutSeconds
        case host
        case port
        case metrics
        case repositoryPath
        case command
        case workingDirectory
        case generatedSource
    }

    private static func rejectUnexpected(
        _ config: AppletConfig,
        allowed: Set<ConfigField>,
        kind: AppletKind
    ) throws {
        let present: [(ConfigField, Bool)] = [
            (.durationSeconds, config.durationSeconds != nil),
            (.autoRestart, config.autoRestart != nil),
            (.url, config.url != nil),
            (.expectedStatusCode, config.expectedStatusCode != nil),
            (.timeoutSeconds, config.timeoutSeconds != nil),
            (.host, config.host != nil),
            (.port, config.port != nil),
            (.metrics, config.metrics != nil),
            (.repositoryPath, config.repositoryPath != nil),
            (.command, config.command != nil),
            (.workingDirectory, config.workingDirectory != nil),
            (.generatedSource, config.generatedSource != nil)
        ]
        let unexpected = present.compactMap { field, isPresent in
            isPresent && !allowed.contains(field) ? field.rawValue : nil
        }
        guard unexpected.isEmpty else {
            throw ManifestValidationError.configMismatch(
                "\(kind.displayName) applets contain unsupported config fields: \(unexpected.joined(separator: ", "))."
            )
        }
    }

    private static func requireMaximumLength(_ value: String, field: String, maximum: Int) throws {
        guard value.count <= maximum else {
            throw ManifestValidationError.valueTooLong(field: field, maximum: maximum)
        }
    }

    private static func trimmed(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func trimmedOptional(_ value: String?) -> String? {
        guard let value else { return nil }
        let result = trimmed(value)
        return result.isEmpty ? nil : result
    }
}

extension AppletManifest {
    static var samples: [AppletManifest] {
        [
            AppletManifest(
                name: "Focus Timer",
                iconSystemName: "timer",
                kind: .timer,
                titleTemplate: "⏱ {{remaining}}",
                sourcePrompt: "Create a 25-minute focus timer.",
                config: AppletConfig(durationSeconds: 25 * 60, autoRestart: false)
            ),
            AppletManifest(
                name: "Port 3000",
                iconSystemName: "network",
                kind: .portMonitor,
                titleTemplate: ":{{port}} {{status}}",
                refreshIntervalSeconds: 5,
                sourcePrompt: "Watch localhost port 3000 and notify me when it goes offline.",
                config: AppletConfig(timeoutSeconds: 2, host: "127.0.0.1", port: 3000)
            ),
            AppletManifest(
                name: "System Load",
                iconSystemName: "cpu",
                kind: .systemMetrics,
                titleTemplate: "CPU {{cpu}} · Mem {{memory}}",
                refreshIntervalSeconds: 2,
                sourcePrompt: "Show CPU and memory usage.",
                config: AppletConfig(metrics: [.cpu, .memory])
            )
        ]
    }
}
