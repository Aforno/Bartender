import CryptoKit
import Foundation

struct GeneratedToolOutput: Codable, Equatable, Sendable {
    var title: String
    var status: String
    var details: [String]
    var healthy: Bool
    var values: [String: String]

    init(
        title: String,
        status: String,
        details: [String] = [],
        healthy: Bool = true,
        values: [String: String] = [:]
    ) {
        self.title = title
        self.status = status
        self.details = details
        self.healthy = healthy
        self.values = values
    }
}

struct GeneratedToolArtifactStore: Sendable {
    enum Error: LocalizedError {
        case revisionChanged

        var errorDescription: String? {
            switch self {
            case .revisionChanged:
                return "Generated source changed before it could run. Review and allow the current version."
            }
        }
    }

    private static let fileLock = NSLock()

    let rootURL: URL

    init(rootURL: URL? = nil) {
        if let rootURL {
            self.rootURL = rootURL
        } else {
            let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
                ?? FileManager.default.temporaryDirectory
            self.rootURL = appSupport
                .appendingPathComponent("BarTender", isDirectory: true)
                .appendingPathComponent("GeneratedTools", isDirectory: true)
        }
    }

    func install(_ manifest: AppletManifest) throws -> URL {
        try Self.withFileLock {
            let source = try Self.normalizedSource(for: manifest)
            let executable = executableURL(for: manifest)
            try Self.writeExecutable(source, to: executable)
            return executable
        }
    }

    /// Resolves an immutable, content-addressed executable for an approved
    /// revision. The canonical artifact for this UUID must already exist and
    /// contain the exact approved source. This prevents an older approved task
    /// from executing a newer, unapproved replacement at the shared path.
    func prepareApprovedExecution(_ manifest: AppletManifest) throws -> URL {
        try Self.withFileLock {
            let source = try Self.normalizedSource(for: manifest)
            let canonicalExecutable = executableURL(for: manifest)
            guard (try? String(contentsOf: canonicalExecutable, encoding: .utf8)) == source else {
                throw Error.revisionChanged
            }

            let digest = SHA256.hash(data: Data(source.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            let revisionExecutable = canonicalExecutable
                .deletingLastPathComponent()
                .appendingPathComponent("Revisions", isDirectory: true)
                .appendingPathComponent(digest, isDirectory: true)
                .appendingPathComponent("tool.zsh", isDirectory: false)
            try Self.writeExecutable(source, to: revisionExecutable)
            return revisionExecutable
        }
    }

    /// Rechecks the shared artifact after any suspension between preparation
    /// and launch. The revision executable itself is content-addressed, so a
    /// replacement after this check can never change what this invocation runs.
    func validateApprovedExecution(_ manifest: AppletManifest, executable: URL) throws {
        try Self.withFileLock {
            let source = try Self.normalizedSource(for: manifest)
            let canonicalExecutable = executableURL(for: manifest)
            let digest = SHA256.hash(data: Data(source.utf8))
                .map { String(format: "%02x", $0) }
                .joined()
            let expectedRevisionExecutable = canonicalExecutable
                .deletingLastPathComponent()
                .appendingPathComponent("Revisions", isDirectory: true)
                .appendingPathComponent(digest, isDirectory: true)
                .appendingPathComponent("tool.zsh", isDirectory: false)

            guard executable.standardizedFileURL == expectedRevisionExecutable.standardizedFileURL,
                  (try? String(contentsOf: canonicalExecutable, encoding: .utf8)) == source,
                  (try? String(contentsOf: executable, encoding: .utf8)) == source else {
                throw Error.revisionChanged
            }
        }
    }

    func remove(id: UUID) throws {
        try Self.withFileLock {
            let directory = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
            guard FileManager.default.fileExists(atPath: directory.path) else { return }
            try FileManager.default.removeItem(at: directory)
        }
    }

    func removeAll() throws {
        try Self.withFileLock {
            guard FileManager.default.fileExists(atPath: rootURL.path) else { return }
            try FileManager.default.removeItem(at: rootURL)
        }
    }

    private func executableURL(for manifest: AppletManifest) -> URL {
        rootURL
            .appendingPathComponent(manifest.id.uuidString, isDirectory: true)
            .appendingPathComponent("tool.zsh", isDirectory: false)
    }

    private static func normalizedSource(for manifest: AppletManifest) throws -> String {
        guard manifest.kind == .generatedTool,
              let source = manifest.config.generatedSource else {
            throw ManifestValidationError.missingGeneratedSource
        }
        return source.hasSuffix("\n") ? source : source + "\n"
    }

    private static func writeExecutable(_ source: String, to executable: URL) throws {
        let fileManager = FileManager.default
        try fileManager.createDirectory(
            at: executable.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let existing = try? String(contentsOf: executable, encoding: .utf8)
        if existing != source {
            try source.write(to: executable, atomically: true, encoding: .utf8)
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executable.path
        )
    }

    private static func withFileLock<T>(_ operation: () throws -> T) rethrows -> T {
        fileLock.lock()
        defer { fileLock.unlock() }
        return try operation()
    }
}

enum GeneratedToolRunner {
    struct Result: Sendable {
        var output: GeneratedToolOutput?
        var message: String
        var approved: Bool
    }

    static func run(
        manifest: AppletManifest,
        approved: Bool,
        artifactStore: GeneratedToolArtifactStore = GeneratedToolArtifactStore(),
        beforeLaunch: (@Sendable () async -> Void)? = nil
    ) async -> Result {
        guard !Task.isCancelled else {
            return Result(
                output: nil,
                message: ProcessRunnerError.cancelled.localizedDescription,
                approved: approved
            )
        }

        guard approved else {
            return Result(
                output: nil,
                message: "Ready to run — review and allow the generated code.",
                approved: false
            )
        }

        let executable: URL
        do {
            executable = try artifactStore.prepareApprovedExecution(manifest)
        } catch {
            return Result(output: nil, message: "Could not install generated tool: \(error.localizedDescription)", approved: approved)
        }

        let environment = await ShellEnvironment.generatedToolEnvironment()
        let workingDirectory = manifest.config.workingDirectory.map {
            ($0 as NSString).expandingTildeInPath
        }
        let timeout = min(30, max(1, manifest.config.timeoutSeconds ?? 15))

        do {
            if let beforeLaunch {
                await beforeLaunch()
            }
            guard !Task.isCancelled else {
                throw ProcessRunnerError.cancelled
            }
            try artifactStore.validateApprovedExecution(manifest, executable: executable)
            let process = try await ProcessRunner().run(
                executable: executable.path,
                arguments: [],
                environment: environment,
                currentDirectory: workingDirectory,
                timeout: timeout
            )
            if process.timedOut {
                return Result(output: nil, message: "Generated tool timed out after \(Int(timeout))s.", approved: true)
            }
            guard process.exitCode == 0 else {
                let detail = firstUsefulLine(process.stderr) ?? firstUsefulLine(process.stdout)
                return Result(
                    output: nil,
                    message: detail ?? "Generated tool exited with code \(process.exitCode).",
                    approved: true
                )
            }

            guard let data = process.stdout.data(using: .utf8),
                  let decoded = try? JSONDecoder().decode(GeneratedToolOutput.self, from: data) else {
                let detail = firstUsefulLine(process.stderr) ?? firstUsefulLine(process.stdout)
                return Result(
                    output: nil,
                    message: detail.map { "Generated tool returned invalid JSON: \($0)" }
                        ?? "Generated tool returned invalid JSON.",
                    approved: true
                )
            }
            return Result(output: sanitized(decoded), message: decoded.status, approved: true)
        } catch {
            return Result(output: nil, message: error.localizedDescription, approved: true)
        }
    }

    static func decodeOutput(_ text: String) throws -> GeneratedToolOutput {
        guard let data = text.data(using: .utf8) else {
            throw CocoaError(.fileReadInapplicableStringEncoding)
        }
        return sanitized(try JSONDecoder().decode(GeneratedToolOutput.self, from: data))
    }

    private static func sanitized(_ output: GeneratedToolOutput) -> GeneratedToolOutput {
        let fallbackTitle = output.status.isEmpty ? "Generated Tool" : output.status
        let cleanTitle = TitleRenderer.shortMenuTitle(output.title.isEmpty ? fallbackTitle : output.title)
        let cleanStatus = String((output.status.isEmpty ? cleanTitle : output.status).prefix(240))
        let cleanDetails = output.details.prefix(6).map { String($0.prefix(240)) }
        let cleanValues = sanitizedValues(output.values)
        return GeneratedToolOutput(
            title: cleanTitle,
            status: cleanStatus,
            details: cleanDetails,
            healthy: output.healthy,
            values: cleanValues
        )
    }

    /// Sort first so both the retained 20 entries and collision suffixes are
    /// stable across launches. Distinct long keys can share the same 40-character
    /// prefix, so uniquify them instead of using a trapping dictionary initializer.
    private static func sanitizedValues(_ values: [String: String]) -> [String: String] {
        let maximumKeyLength = 40
        var result: [String: String] = [:]

        for (rawKey, rawValue) in values.sorted(by: { $0.key < $1.key }).prefix(20) {
            let base = String(rawKey.prefix(maximumKeyLength))
            var candidate = base
            var suffixIndex = 2
            while result[candidate] != nil {
                let suffix = "~\(suffixIndex)"
                let prefixLength = max(0, maximumKeyLength - suffix.count)
                candidate = String(base.prefix(prefixLength)) + suffix
                suffixIndex += 1
            }
            result[candidate] = String(rawValue.prefix(240))
        }
        return result
    }

    private static func firstUsefulLine(_ text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
            .map { String($0.prefix(240)) }
    }
}

enum GeneratedToolSourceValidator {
    static func validate(_ manifest: AppletManifest) async throws {
        guard manifest.kind == .generatedTool,
              let source = manifest.config.generatedSource else { return }

        let lowered = source.lowercased()
        let forbiddenPatterns = [
            #"(^|[^a-z0-9_])sudo([^a-z0-9_]|$)"#,
            #"(^|[^a-z0-9_])powermetrics([^a-z0-9_]|$)"#
        ]
        if forbiddenPatterns.contains(where: {
            lowered.range(of: $0, options: .regularExpression) != nil
        }) {
            throw ProviderGenerationError.invalidResponse(
                "The generated source requires administrator-only tooling. Bar Tender rejected it because menu bar tools must refresh unattended without elevated privileges."
            )
        }

        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTender-Syntax-\(UUID().uuidString)", isDirectory: true)
        let interpreter = source.hasPrefix("#!/bin/bash") ? "/bin/bash" : "/bin/zsh"
        let interpreterName = URL(fileURLWithPath: interpreter).lastPathComponent
        let sourceURL = directory.appendingPathComponent("tool.\(interpreterName)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        let result = try await ProcessRunner().run(
            executable: interpreter,
            arguments: ["-n", sourceURL.path],
            timeout: 5
        )
        if result.cancelled {
            throw CancellationError()
        }
        guard !result.timedOut else {
            throw ProviderGenerationError.invalidResponse(
                "Generated source syntax validation timed out."
            )
        }
        guard result.exitCode == 0 else {
            let detail = result.stderr
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init) ?? "\(interpreterName) could not parse the generated source."
            throw ProviderGenerationError.invalidResponse(
                "Generated source failed syntax validation: \(detail)"
            )
        }
    }
}
