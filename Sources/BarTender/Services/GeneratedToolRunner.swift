import Foundation

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
            executable = try await Task.detached(priority: .utility) {
                try artifactStore.prepareApprovedExecution(manifest)
            }.value
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
            try await Task.detached(priority: .utility) {
                try artifactStore.validateApprovedExecution(manifest, executable: executable)
            }.value
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
