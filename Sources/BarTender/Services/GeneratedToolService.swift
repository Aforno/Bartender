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
        guard manifest.kind == .generatedTool,
              let source = manifest.config.generatedSource else {
            throw ManifestValidationError.missingGeneratedSource
        }

        let directory = rootURL.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
        let executable = directory.appendingPathComponent("tool.zsh", isDirectory: false)
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: directory, withIntermediateDirectories: true)

        let normalizedSource = source.hasSuffix("\n") ? source : source + "\n"
        let existing = try? String(contentsOf: executable, encoding: .utf8)
        if existing != normalizedSource {
            try normalizedSource.write(to: executable, atomically: true, encoding: .utf8)
        }
        try fileManager.setAttributes(
            [.posixPermissions: NSNumber(value: Int16(0o700))],
            ofItemAtPath: executable.path
        )
        return executable
    }

    func remove(id: UUID) throws {
        let directory = rootURL.appendingPathComponent(id.uuidString, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        try FileManager.default.removeItem(at: directory)
    }

    func removeAll() throws {
        guard FileManager.default.fileExists(atPath: rootURL.path) else { return }
        try FileManager.default.removeItem(at: rootURL)
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
        artifactStore: GeneratedToolArtifactStore = GeneratedToolArtifactStore()
    ) async -> Result {
        let executable: URL
        do {
            executable = try artifactStore.install(manifest)
        } catch {
            return Result(output: nil, message: "Could not install generated tool: \(error.localizedDescription)", approved: approved)
        }

        guard approved else {
            return Result(
                output: nil,
                message: "Ready to run — review and allow the generated code.",
                approved: false
            )
        }

        let environment = await ShellEnvironment.generatedToolEnvironment()
        let workingDirectory = manifest.config.workingDirectory.map {
            ($0 as NSString).expandingTildeInPath
        }
        let timeout = min(30, max(1, manifest.config.timeoutSeconds ?? 15))

        do {
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
                let detail = firstUsefulLine(process.stderr)
                return Result(
                    output: nil,
                    message: detail ?? "Generated tool returned invalid JSON.",
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
        let cleanValues = Dictionary(uniqueKeysWithValues: output.values.prefix(20).map {
            (String($0.key.prefix(40)), String($0.value.prefix(240)))
        })
        return GeneratedToolOutput(
            title: cleanTitle,
            status: cleanStatus,
            details: cleanDetails,
            healthy: output.healthy,
            values: cleanValues
        )
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
            #"(^|/)powermetrics([^a-z0-9_]|$)"#
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
        let sourceURL = directory.appendingPathComponent("tool.zsh")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        try source.write(to: sourceURL, atomically: true, encoding: .utf8)

        let result = try await ProcessRunner().run(
            executable: "/bin/zsh",
            arguments: ["-n", sourceURL.path],
            timeout: 5
        )
        guard result.exitCode == 0, !result.timedOut else {
            let detail = result.stderr
                .split(whereSeparator: \.isNewline)
                .first
                .map(String.init) ?? "zsh could not parse the generated source."
            throw ProviderGenerationError.invalidResponse(
                "Generated source failed syntax validation: \(detail)"
            )
        }
    }
}
