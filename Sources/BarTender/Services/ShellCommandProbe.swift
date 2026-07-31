import Foundation

enum ShellCommandProbe {
    struct Result: Sendable {
        var ok: Bool
        var output: String
        var exitCode: Int32
        var message: String
    }

    static func run(
        command: String,
        workingDirectory: String?,
        approved: Bool
    ) async -> Result {
        guard approved else {
            return Result(
                ok: false,
                output: "",
                exitCode: -1,
                message: "Shell command not approved. Review and allow it on the tool's page."
            )
        }

        let env = await ShellEnvironment.loginEnvironment()
        let shell = env["SHELL"] ?? "/bin/zsh"
        let runner = ProcessRunner()
        let cwd = workingDirectory.map { ($0 as NSString).expandingTildeInPath }
        let timeoutSeconds = 30

        do {
            let result = try await runner.run(
                executable: shell,
                arguments: ["-lc", command],
                environment: env,
                currentDirectory: cwd,
                timeout: TimeInterval(timeoutSeconds)
            )
            return interpret(result, timeoutSeconds: timeoutSeconds)
        } catch {
            return Result(
                ok: false,
                output: "",
                exitCode: -1,
                message: Task.isCancelled ? "Cancelled" : error.localizedDescription
            )
        }
    }

    static func interpret(
        _ process: ProcessResult,
        timeoutSeconds: Int
    ) -> Result {
        let stdout = process.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        let stderr = process.stderr.trimmingCharacters(in: .whitespacesAndNewlines)

        let message: String
        let ok: Bool
        if process.cancelled {
            ok = false
            message = "Cancelled"
        } else if process.timedOut {
            ok = false
            message = "Timed out after \(timeoutSeconds)s"
        } else if process.exitCode == 0 {
            ok = true
            message = firstLine(in: stdout) ?? "OK"
        } else {
            ok = false
            message = firstLine(in: stderr)
                ?? firstLine(in: stdout)
                ?? "Exit \(process.exitCode)"
        }

        return Result(
            ok: ok,
            output: stdout,
            exitCode: process.exitCode,
            message: TitleRenderer.shortMenuTitle(message)
        )
    }

    private static func firstLine(in text: String) -> String? {
        text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
    }
}
