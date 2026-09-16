import Foundation

enum GeneratedToolSourceValidator {
    /// Advisory UX: the prompt and these two patterns reject common
    /// administrator-only commands. They are not a sandbox. Approved tools
    /// still run with the user's privileges.
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
