import Foundation

enum GitStatusProbe {
    struct Result: Sendable {
        var ok: Bool
        var branch: String
        var changedFiles: Int
        var message: String
    }

    static func probe(repositoryPath: String) async -> Result {
        let expanded = (repositoryPath as NSString).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue else {
            return Result(ok: false, branch: "—", changedFiles: 0, message: "Path not found")
        }

        let env = await ShellEnvironment.loginEnvironment()
        guard let git = ShellEnvironment.which("git", environment: env) else {
            return Result(ok: false, branch: "—", changedFiles: 0, message: "git not found")
        }

        let runner = ProcessRunner()
        do {
            let branchResult = try await runner.run(
                executable: git,
                arguments: ["-C", expanded, "rev-parse", "--abbrev-ref", "HEAD"],
                environment: env,
                timeout: 10
            )
            if let failure = failureMessage(
                for: branchResult,
                operation: "Reading branch",
                fallback: "Not a git repository"
            ) {
                return Result(ok: false, branch: "—", changedFiles: 0, message: failure)
            }
            let branch = branchResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)

            let statusResult = try await runner.run(
                executable: git,
                arguments: ["-C", expanded, "status", "--porcelain"],
                environment: env,
                timeout: 15
            )
            if let failure = failureMessage(
                for: statusResult,
                operation: "Reading status",
                fallback: "git status failed"
            ) {
                return Result(ok: false, branch: branch, changedFiles: 0, message: failure)
            }
            let lines = statusResult.stdout
                .split(whereSeparator: \.isNewline)
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
            return Result(
                ok: true,
                branch: branch.isEmpty ? "HEAD" : branch,
                changedFiles: lines.count,
                message: "\(branch) · \(lines.count) changed"
            )
        } catch {
            return Result(
                ok: false,
                branch: "—",
                changedFiles: 0,
                message: Task.isCancelled ? "Cancelled" : error.localizedDescription
            )
        }
    }

    static func failureMessage(
        for process: ProcessResult,
        operation: String,
        fallback: String
    ) -> String? {
        if process.cancelled {
            return "Cancelled"
        }
        if process.timedOut {
            return "\(operation) timed out"
        }
        guard process.exitCode != 0 else { return nil }

        let detail = process.stderr
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .first(where: { !$0.isEmpty })
        return detail.map { TitleRenderer.shortMenuTitle($0) } ?? fallback
    }
}
