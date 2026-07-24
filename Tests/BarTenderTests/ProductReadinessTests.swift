import Foundation
import XCTest
@testable import BarTender

final class ProductReadinessTests: XCTestCase {
    func testBundledProviderIconsExistAndDecode() throws {
        for provider in AIProvider.allCases {
            let url = AppResources.bundle.url(
                forResource: provider.iconResourceName,
                withExtension: "png",
                subdirectory: "ProviderIcons"
            ) ?? AppResources.bundle.url(forResource: provider.iconResourceName, withExtension: "png")
            let resolved = try XCTUnwrap(url, "Missing icon for \(provider.displayName)")
            XCTAssertGreaterThan(try Data(contentsOf: resolved).count, 1_000)
        }
    }

    @MainActor
    func testStatusItemOverflowKeepsOnlyEightIndividualItems() {
        let applets = (0..<12).map { index in
            AppletManifest(
                name: "Tool \(index)",
                iconSystemName: "gear",
                kind: .systemMetrics,
                titleTemplate: "{{value}}",
                config: AppletConfig(metrics: [.cpu])
            )
        }
        let visible = StatusItemManager.individuallyVisible(from: applets)
        XCTAssertEqual(visible.count, 8)
        XCTAssertEqual(visible.map(\.id), Array(applets.prefix(8)).map(\.id))
    }

    func testUpdateVersionComparisonHandlesDriftAndPrereleases() {
        XCTAssertTrue(UpdateService.isVersion("2.0.0", newerThan: "1.9.9"))
        XCTAssertTrue(UpdateService.isVersion("1.10.0", newerThan: "1.9.9"))
        XCTAssertFalse(UpdateService.isVersion("1.0.0", newerThan: "1.0.0"))
        XCTAssertFalse(UpdateService.isVersion("0.9.9", newerThan: "1.0.0"))
        XCTAssertTrue(UpdateService.isVersion("1.0.1-beta.1", newerThan: "1.0.0"))
    }

    func testGeneratedToolEnvironmentUsesAnExplicitAllowlist() async {
        let environment = await ShellEnvironment.generatedToolEnvironment()
        let allowed = Set([
            "HOME", "USER", "LOGNAME", "PATH", "SHELL", "TMPDIR",
            "LANG", "LC_ALL", "LC_CTYPE", "TERM", "NO_COLOR", "BARTENDER_CLI"
        ])
        XCTAssertTrue(Set(environment.keys).isSubset(of: allowed))
        XCTAssertNil(environment["OPENAI_API_KEY"])
        XCTAssertNil(environment["ANTHROPIC_API_KEY"])
        XCTAssertNil(environment["GITHUB_TOKEN"])
    }

    @MainActor
    func testLongTitlesAndProviderLogsStayBounded() {
        let title = String(repeating: "Long menu title ", count: 20)
        let shortened = TitleRenderer.shortMenuTitle(title)
        XCTAssertEqual(shortened.count, TitleRenderer.menuBarMaxLength)
        XCTAssertTrue(shortened.hasSuffix("…"))

        let session = GenerationSession(prompt: "Long log", provider: .codex)
        for index in 0..<2_500 {
            session.append(stream: .stdout, "line \(index)")
        }
        XCTAssertEqual(session.logs.count, GenerationSession.maximumLogLines)
        XCTAssertEqual(session.logs.first?.text, "line 500")
        XCTAssertEqual(session.logs.last?.text, "line 2499")
    }
}

@MainActor
final class ProviderEndToEndMatrixTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var executablePaths: [String: String] = [:]

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTender-ProviderMatrix-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory.appendingPathComponent(".grok", isDirectory: true),
            withIntermediateDirectories: true
        )
        try #"{"token":"fixture"}"#.write(
            to: temporaryDirectory.appendingPathComponent(".grok/auth.json"),
            atomically: true,
            encoding: .utf8
        )
        try FileManager.default.createDirectory(
            at: temporaryDirectory.appendingPathComponent(".gemini/antigravity-cli", isDirectory: true),
            withIntermediateDirectories: true
        )
        try #"{"access_token":"fixture"}"#.write(
            to: temporaryDirectory.appendingPathComponent(".gemini/oauth_creds.json"),
            atomically: true,
            encoding: .utf8
        )
        try "fixture-oauth-token".write(
            to: temporaryDirectory.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token"),
            atomically: true,
            encoding: .utf8
        )
        defaultsSuite = "BarTenderTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)!
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        if let defaults {
            defaults.removePersistentDomain(forName: defaultsSuite)
        }
        executablePaths = [:]
    }

    func testAllProvidersProbeAndGenerateThroughRealProcesses() async throws {
        try installHealthyProviderFixtures()
        let service = makeService()
        await service.refreshAvailability()

        for provider in AIProvider.allCases {
            guard case .ready(let installation) = service.status(for: provider) else {
                return XCTFail("\(provider.displayName) did not become ready")
            }
            XCTAssertTrue(installation.version.contains("fixture"))
            let manifest = try await service.generateManifest(
                prompt: "Build a fixture",
                provider: provider,
                onLog: { _, _ in }
            )
            XCTAssertEqual(manifest.kind, .generatedTool)
            XCTAssertEqual(manifest.sourcePrompt, "Build a fixture")
            XCTAssertEqual(manifest.name, "Matrix Tool")
        }
    }

    func testMissingCLIsAreReportedIndividually() async {
        let service = makeService()
        await service.refreshAvailability()
        for provider in AIProvider.allCases {
            XCTAssertEqual(service.status(for: provider), .unavailable(.notFound))
        }
    }

    func testUnauthenticatedAndExpiredProvidersAreRejected() async throws {
        try installFixture(named: "codex", source: probeScript(
            version: "codex fixture",
            authMatcher: "login",
            authOutput: "Not logged in"
        ))
        try installFixture(named: "claude", source: probeScript(
            version: "claude fixture",
            authMatcher: "auth",
            authOutput: #"{"loggedIn":false}"#
        ))
        try installFixture(named: "grok", source: probeScript(
            version: "grok fixture",
            authMatcher: "models",
            authOutput: "auth: token expired, re-authentication required"
        ))
        try installFixture(named: "gemini", source: probeScript(
            version: "gemini fixture",
            authMatcher: "unused",
            authOutput: "unused"
        ))
        try installFixture(named: "agy", source: probeScript(
            version: "agy fixture",
            authMatcher: "models",
            authOutput: "auth: token expired, re-authentication required"
        ))
        // Gemini and Antigravity probe local credential files before CLI checks.
        try? FileManager.default.removeItem(
            at: temporaryDirectory.appendingPathComponent(".gemini/oauth_creds.json")
        )
        try? FileManager.default.removeItem(
            at: temporaryDirectory.appendingPathComponent(".gemini/antigravity-cli/antigravity-oauth-token")
        )

        let service = makeService()
        await service.refreshAvailability()
        for provider in AIProvider.allCases {
            guard case .unavailable(.notAuthenticated) = service.status(for: provider) else {
                return XCTFail("\(provider.displayName) should require authentication")
            }
        }
    }

    func testMalformedProviderOutputFailsClosed() async throws {
        try installHealthyProviderFixtures(generationOutput: "not-json")
        let service = makeService()
        await service.refreshAvailability()

        do {
            _ = try await service.generateManifest(
                prompt: "Malformed please",
                provider: .claude,
                onLog: { _, _ in }
            )
            XCTFail("Malformed output unexpectedly succeeded")
        } catch let error as ProviderGenerationError {
            guard case .invalidResponse = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    func testGenerationRevocationDowngradesProviderImmediately() async throws {
        let envelope = #"{"type":"result","is_error":true,"result":"Failed to authenticate. API Error: 401 OAuth access token has been revoked."}"#
        try installHealthyProviderFixtures(generationOutput: envelope)
        let service = makeService()
        await service.refreshAvailability()

        do {
            _ = try await service.generateManifest(
                prompt: "Discover revoked token",
                provider: .claude,
                onLog: { _, _ in }
            )
            XCTFail("Revoked authentication unexpectedly generated a tool")
        } catch let error as ProviderGenerationError {
            guard case .authenticationExpired(.claude) = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
        guard case .unavailable(.notAuthenticated) = service.status(for: .claude) else {
            return XCTFail("Claude should be downgraded after a live 401")
        }
    }

    func testGenerationCanBeCancelledWithoutAnyGenerationTimeout() async throws {
        try installHealthyProviderFixtures(generationDelay: 5)
        let service = makeService()
        await service.refreshAvailability()
        let launched = expectation(description: "Provider generation launched")

        let task = Task {
            try await service.generateManifest(
                prompt: "Wait for cancellation",
                provider: .claude,
                onLog: { stream, message in
                    if stream == .system, message.hasPrefix("Launching:") {
                        launched.fulfill()
                    }
                }
            )
        }
        await fulfillment(of: [launched], timeout: 2)
        await Task.yield()
        service.cancelGeneration()

        do {
            _ = try await task.value
            XCTFail("Cancelled generation unexpectedly succeeded")
        } catch let error as ProviderGenerationError {
            guard case .cancelled = error else {
                return XCTFail("Unexpected error: \(error)")
            }
        }
    }

    private func makeService() -> AIProviderService {
        let environment = [
            "PATH": temporaryDirectory.path,
            "HOME": temporaryDirectory.path,
            "USER": "fixture",
            "LOGNAME": "fixture"
        ]
        return AIProviderService(
            defaults: defaults,
            environmentLoader: { environment },
            homeDirectoryURL: temporaryDirectory,
            modelProvider: { provider in
                [AIModelOption(provider: provider, modelID: "fixture-model", isDefault: true)]
            },
            executableResolver: { [executablePaths] name, _ in executablePaths[name] }
        )
    }

    private func installHealthyProviderFixtures(
        generationOutput: String? = nil,
        generationDelay: Int = 0
    ) throws {
        let output = generationOutput ?? Self.validManifest
        try installFixture(
            named: "codex",
            source: providerScript(
                version: "codex fixture 99.0-nightly",
                authMatcher: "login",
                authOutput: "Logged in using fixture",
                generationOutput: output,
                generationDelay: generationDelay,
                writesOutputFile: true
            )
        )
        try installFixture(
            named: "claude",
            source: providerScript(
                version: "claude fixture 99.0-nightly",
                authMatcher: "auth",
                authOutput: #"{"loggedIn":true,"authMethod":"fixture"}"#,
                generationOutput: output,
                generationDelay: generationDelay
            )
        )
        try installFixture(
            named: "grok",
            source: providerScript(
                version: "grok fixture 99.0-nightly",
                authMatcher: "models",
                authOutput: "Available models: fixture-model",
                generationOutput: output,
                generationDelay: generationDelay
            )
        )
        try installFixture(
            named: "gemini",
            source: providerScript(
                version: "gemini fixture 99.0-nightly",
                authMatcher: "unused",
                authOutput: "unused",
                generationOutput: geminiEnvelope(for: output),
                generationDelay: generationDelay
            )
        )
        try installFixture(
            named: "agy",
            source: providerScript(
                version: "agy fixture 99.0-nightly",
                authMatcher: "models",
                authOutput: "gemini-3.1-pro-high\ngemini-3.6-flash-medium",
                generationOutput: output,
                generationDelay: generationDelay
            )
        )
    }

    /// Gemini `--output-format json` wraps the assistant answer in a `response` field.
    private func geminiEnvelope(for generationOutput: String) -> String {
        let escaped = generationOutput
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "\n", with: "\\n")
        return #"{"response":"\#(escaped)","stats":{"models":{}}}"#
    }

    private func installFixture(named name: String, source: String) throws {
        let url = temporaryDirectory.appendingPathComponent(name)
        try source.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        executablePaths[name] = url.path
    }

    private func probeScript(version: String, authMatcher: String, authOutput: String) -> String {
        """
        #!/bin/sh
        if [ "$1" = "--version" ]; then printf '%s\\n' '\(version)'; exit 0; fi
        if [ "$1" = "\(authMatcher)" ]; then printf '%s\\n' '\(authOutput)' >&2; exit 0; fi
        exit 1
        """
    }

    private func providerScript(
        version: String,
        authMatcher: String,
        authOutput: String,
        generationOutput: String,
        generationDelay: Int,
        writesOutputFile: Bool = false
    ) -> String {
        let delivery: String
        if writesOutputFile {
            delivery = """
            output_file=''
            while [ "$#" -gt 0 ]; do
              if [ "$1" = "--output-last-message" ]; then shift; output_file="$1"; fi
              shift
            done
            printf '%s\\n' '\(generationOutput)' > "$output_file"
            """
        } else {
            delivery = "printf '%s\\n' '\(generationOutput)'"
        }
        return """
        #!/bin/sh
        if [ "$1" = "--version" ]; then printf '%s\\n' '\(version)'; exit 0; fi
        if [ "$1" = "\(authMatcher)" ]; then printf '%s\\n' '\(authOutput)'; exit 0; fi
        sleep \(generationDelay)
        \(delivery)
        """
    }

    private static let validManifest = ##"{"name":"Matrix Tool","iconSystemName":"gear","kind":"generatedTool","titleTemplate":"{{value}}","refreshIntervalSeconds":30,"notifyOnComplete":false,"notifyOnFailure":false,"config":{"timeoutSeconds":5,"generatedSource":"#!/bin/zsh\\nprintf '{\\\"title\\\":\\\"OK\\\",\\\"status\\\":\\\"OK\\\",\\\"details\\\":[],\\\"healthy\\\":true,\\\"values\\\":{\\\"value\\\":\\\"OK\\\"}}'"}}"##
}
