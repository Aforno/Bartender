import Foundation

enum ShellEnvironment {
    private static let cache = LoginEnvironmentCache()
    private static let loginShellTimeout: TimeInterval = 3

    /// Builds and caches an environment map that mirrors the user's login shell PATH/HOME.
    static func loginEnvironment() async -> [String: String] {
        await cache.environment()
    }

    /// Environment exposed to approved generated tools. Authentication tokens
    /// inherited by the app are intentionally excluded; tools still receive the
    /// standard user identity, locale, temporary directory, shell, and PATH.
    /// BARTENDER_CLI points at a sensor-only wrapper (not the GUI executable) so
    /// tools can run `"$BARTENDER_CLI" --sensors` without launching a second app
    /// instance that would race on applets.json / UserDefaults.
    static func generatedToolEnvironment() async -> [String: String] {
        let login = await loginEnvironment()
        let allowedKeys = [
            "HOME", "USER", "LOGNAME", "PATH", "SHELL", "TMPDIR",
            "LANG", "LC_ALL", "LC_CTYPE", "TERM", "NO_COLOR"
        ]
        var environment = Dictionary(uniqueKeysWithValues: allowedKeys.compactMap { key in
            login[key].map { (key, $0) }
        })
        if let cliPath = ensureSensorCLIWrapper() {
            environment["BARTENDER_CLI"] = cliPath
        }
        return environment
    }

    /// Writes (or refreshes) a small zsh wrapper that only allows `--sensors` /
    /// `--sensors-json` and execs the real app binary for those flags. Bare or
    /// unknown invocations exit with an error instead of opening a full GUI.
    static func ensureSensorCLIWrapper(
        appExecutable: String? = Bundle.main.executableURL?.path,
        fileManager: FileManager = .default
    ) -> String? {
        guard let appExecutable, !appExecutable.isEmpty else { return nil }

        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? fileManager.temporaryDirectory
        let binDirectory = appSupport
            .appendingPathComponent("BarTender", isDirectory: true)
            .appendingPathComponent("bin", isDirectory: true)
        let wrapperURL = binDirectory.appendingPathComponent("bartender-cli", isDirectory: false)

        // Single-quote the app path for zsh; escape any embedded single quotes.
        let escapedApp = appExecutable.replacingOccurrences(of: "'", with: "'\\''")
        let wrapperScript = """
        #!/bin/zsh
        set -euo pipefail
        APP='\(escapedApp)'
        if [[ $# -lt 1 ]]; then
          print -u2 'Bar Tender CLI supports only --sensors and --sensors-json.'
          exit 2
        fi
        case "$1" in
          --sensors|--sensors-json)
            exec "$APP" "$@"
            ;;
          *)
            print -u2 'Bar Tender CLI supports only --sensors and --sensors-json.'
            exit 2
            ;;
        esac
        """

        do {
            try fileManager.createDirectory(at: binDirectory, withIntermediateDirectories: true)
            let existing = try? String(contentsOf: wrapperURL, encoding: .utf8)
            if existing != wrapperScript {
                try wrapperScript.write(to: wrapperURL, atomically: true, encoding: .utf8)
            }
            try fileManager.setAttributes(
                [.posixPermissions: NSNumber(value: Int16(0o755))],
                ofItemAtPath: wrapperURL.path
            )
            return wrapperURL.path
        } catch {
            AppLog.app.error(
                "Could not install BARTENDER_CLI wrapper: \(error.localizedDescription, privacy: .public)"
            )
            return nil
        }
    }

    fileprivate static func buildLoginEnvironment() async -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = await resolveLoginPATH() ?? safeFallbackPATH()
        if env["HOME"] == nil {
            env["HOME"] = NSHomeDirectory()
        }
        if env["USER"] == nil {
            env["USER"] = NSUserName()
        }
        // Prefer non-interactive color for tooling.
        env["TERM"] = env["TERM"] ?? "dumb"
        env["NO_COLOR"] = "1"
        return env
    }

    static func resolveLoginPATH() async -> String? {
        let fallback = safeFallbackPATH()
        let shell = ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
        let runner = ProcessRunner()

        do {
            let result = try await runner.run(
                executable: shell,
                arguments: ["-l", "-c", "printenv PATH"],
                environment: [
                    "HOME": NSHomeDirectory(),
                    "USER": NSUserName(),
                    "LOGNAME": NSUserName()
                ],
                timeout: loginShellTimeout
            )
            guard !result.timedOut,
                  !result.cancelled,
                  result.exitCode == 0,
                  let path = result.stdout
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                    .nonEmpty else {
                return fallback
            }
            return mergePATH(path, with: fallback)
        } catch {
            return fallback
        }
    }

    static func fallbackPATH() -> String {
        let home = NSHomeDirectory()
        let candidates = [
            "/opt/homebrew/bin",
            "/opt/homebrew/sbin",
            "/usr/local/bin",
            "/usr/local/sbin",
            "\(home)/.local/bin",
            "\(home)/.cargo/bin",
            "\(home)/.npm-global/bin",
            "/usr/bin",
            "/bin",
            "/usr/sbin",
            "/sbin"
        ]
        return candidates.joined(separator: ":")
    }

    static func mergePATH(_ primary: String, with secondary: String) -> String {
        var seen = Set<String>()
        var parts: [String] = []
        for item in (primary.split(separator: ":") + secondary.split(separator: ":")).map(String.init) {
            if seen.insert(item).inserted {
                parts.append(item)
            }
        }
        return parts.joined(separator: ":")
    }

    static func which(_ executable: String, environment: [String: String]? = nil) -> String? {
        let env = environment ?? ProcessInfo.processInfo.environment
        let path = env["PATH"].map { mergePATH($0, with: fallbackPATH()) } ?? fallbackPATH()
        for directory in path.split(separator: ":").map(String.init) {
            let candidate = (directory as NSString).appendingPathComponent(executable)
            if FileManager.default.isExecutableFile(atPath: candidate) {
                return candidate
            }
        }

        // Absolute / common hard-coded fallbacks.
        let hardCoded = [
            "/opt/homebrew/bin/\(executable)",
            "/usr/local/bin/\(executable)",
            "\(NSHomeDirectory())/.local/bin/\(executable)"
        ]
        return hardCoded.first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    private static func safeFallbackPATH() -> String {
        let inherited = ProcessInfo.processInfo.environment["PATH"] ?? ""
        return mergePATH(inherited, with: fallbackPATH())
    }
}

private actor LoginEnvironmentCache {
    private var cachedEnvironment: [String: String]?
    private var resolutionTask: Task<[String: String], Never>?

    func environment() async -> [String: String] {
        if let cachedEnvironment {
            return cachedEnvironment
        }
        if let resolutionTask {
            return await resolutionTask.value
        }

        let task = Task {
            await ShellEnvironment.buildLoginEnvironment()
        }
        resolutionTask = task
        let environment = await task.value
        cachedEnvironment = environment
        resolutionTask = nil
        return environment
    }
}

private extension String {
    var nonEmpty: String? {
        isEmpty ? nil : self
    }
}
