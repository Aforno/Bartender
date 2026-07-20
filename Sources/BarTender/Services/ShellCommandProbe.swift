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
                message: "Shell command not approved. Enable approval in the inspector."
            )
        }

        let env = await ShellEnvironment.loginEnvironment()
        let shell = env["SHELL"] ?? "/bin/zsh"
        let runner = ProcessRunner()
        let cwd = workingDirectory.map { ($0 as NSString).expandingTildeInPath }

        do {
            let result = try await runner.run(
                executable: shell,
                arguments: ["-lc", command],
                environment: env,
                currentDirectory: cwd,
                timeout: 30
            )
            let output = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            let firstLine = output.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            let display = firstLine.isEmpty ? (result.exitCode == 0 ? "OK" : "Exit \(result.exitCode)") : firstLine
            return Result(
                ok: result.exitCode == 0,
                output: output,
                exitCode: result.exitCode,
                message: TitleRenderer.shortMenuTitle(display)
            )
        } catch {
            return Result(ok: false, output: "", exitCode: -1, message: error.localizedDescription)
        }
    }
}
