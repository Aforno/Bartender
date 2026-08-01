import Foundation
import XCTest
@testable import BarTender

@MainActor
final class GeminiProviderAuthenticationTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var defaults: UserDefaults!
    private var defaultsSuite: String!
    private var geminiExecutable: URL!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTender-GeminiAuth-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(
            at: temporaryDirectory,
            withIntermediateDirectories: true
        )
        geminiExecutable = temporaryDirectory.appendingPathComponent("gemini")
        try """
        #!/bin/sh
        if [ "$1" = "--version" ]; then
          printf '%s\\n' 'gemini fixture 99.0'
          exit 0
        fi
        exit 1
        """.write(to: geminiExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes(
            [.posixPermissions: 0o755],
            ofItemAtPath: geminiExecutable.path
        )

        defaultsSuite = "BarTenderTests.GeminiAuth.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuite)!
    }

    override func tearDownWithError() throws {
        if let temporaryDirectory {
            try? FileManager.default.removeItem(at: temporaryDirectory)
        }
        if let defaults {
            defaults.removePersistentDomain(forName: defaultsSuite)
        }
    }

    func testOAuthUsesEffectiveGeminiCLIHome() async throws {
        let configuredRoot = temporaryDirectory
            .appendingPathComponent("isolated-gemini-home", isDirectory: true)
        let configDirectory = configuredRoot.appendingPathComponent(".gemini", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        try #"{"access_token":"fixture-token"}"#.write(
            to: configDirectory.appendingPathComponent("oauth_creds.json"),
            atomically: true,
            encoding: .utf8
        )
        try #"{"security":{"auth":{"selectedType":"oauth-personal"}}}"#.write(
            to: configDirectory.appendingPathComponent("settings.json"),
            atomically: true,
            encoding: .utf8
        )

        let service = makeService(environment: [
            "GEMINI_CLI_HOME": configuredRoot.path
        ])
        await service.refreshAvailability()

        let installation = try readyGeminiInstallation(from: service)
        XCTAssertEqual(installation.authSummary, "Authenticated with Google OAuth")
        XCTAssertFalse(String(describing: service.status(for: .gemini)).contains("fixture-token"))
    }

    func testBareOAuthFileWithoutAuthSelectionFailsClosed() async throws {
        let configDirectory = temporaryDirectory.appendingPathComponent(".gemini", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        try #"{"access_token":"fixture-token"}"#.write(
            to: configDirectory.appendingPathComponent("oauth_creds.json"),
            atomically: true,
            encoding: .utf8
        )

        let service = makeService(environment: [:])
        await service.refreshAvailability()

        guard case .unavailable(.notAuthenticated) = service.status(for: .gemini) else {
            return XCTFail("Gemini noninteractive mode should require an effective auth selection")
        }
    }

    func testGeminiAPIKeyEnvironmentIsAcceptedWithoutExposingSecret() async throws {
        let secret = "gemini-secret-sentinel"
        let service = makeService(environment: ["GEMINI_API_KEY": secret])
        await service.refreshAvailability()

        let installation = try readyGeminiInstallation(from: service)
        XCTAssertEqual(installation.authSummary, "Gemini API key configured")
        XCTAssertFalse(installation.authSummary.contains(secret))
        XCTAssertFalse(String(describing: service.status(for: .gemini)).contains(secret))
    }

    func testVertexEnvironmentIsAcceptedWithoutExposingConfigurationValues() async throws {
        let project = "sensitive-project-sentinel"
        let location = "sensitive-location-sentinel"
        let credentialsURL = temporaryDirectory.appendingPathComponent("credentials-sentinel.json")
        try #"{"type":"service_account"}"#.write(
            to: credentialsURL,
            atomically: true,
            encoding: .utf8
        )
        let credentialsPath = credentialsURL.path
        let service = makeService(environment: [
            "GOOGLE_GENAI_USE_VERTEXAI": "true",
            "GOOGLE_CLOUD_PROJECT": project,
            "GOOGLE_CLOUD_LOCATION": location,
            "GOOGLE_APPLICATION_CREDENTIALS": credentialsPath
        ])
        await service.refreshAvailability()

        let installation = try readyGeminiInstallation(from: service)
        XCTAssertEqual(installation.authSummary, "Vertex AI credentials configured")
        for value in [project, location, credentialsPath] {
            XCTAssertFalse(installation.authSummary.contains(value))
            XCTAssertFalse(String(describing: service.status(for: .gemini)).contains(value))
        }
    }

    func testVertexEnvironmentRejectsUnreadableExplicitADCCredentials() async {
        let service = makeService(environment: [
            "GOOGLE_GENAI_USE_VERTEXAI": "true",
            "GOOGLE_CLOUD_PROJECT": "fixture-project",
            "GOOGLE_CLOUD_LOCATION": "fixture-location",
            "GOOGLE_APPLICATION_CREDENTIALS": temporaryDirectory
                .appendingPathComponent("missing-credentials.json")
                .path
        ])
        await service.refreshAvailability()

        guard case .unavailable(.notAuthenticated(let summary)) = service.status(for: .gemini) else {
            return XCTFail("Gemini should reject an explicit unreadable ADC credential file")
        }
        XCTAssertTrue(summary.contains("Vertex AI"))
        XCTAssertFalse(summary.contains("missing-credentials.json"))
    }

    func testPersistedVertexSelectionUsesAmbientADCEnvironment() async throws {
        let configDirectory = temporaryDirectory.appendingPathComponent(".gemini", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        try #"{"security":{"auth":{"selectedType":"vertex-ai"}}}"#.write(
            to: configDirectory.appendingPathComponent("settings.json"),
            atomically: true,
            encoding: .utf8
        )

        let service = makeService(environment: [
            "GOOGLE_CLOUD_PROJECT": "fixture-project",
            "GOOGLE_CLOUD_LOCATION": "fixture-location"
        ])
        await service.refreshAvailability()

        let installation = try readyGeminiInstallation(from: service)
        XCTAssertEqual(installation.authSummary, "Vertex AI credentials configured")
    }

    func testIncompleteVertexSelectionWinsOverGeminiAPIKeyEnvironment() async {
        let service = makeService(environment: [
            "GOOGLE_GENAI_USE_VERTEXAI": "true",
            "GEMINI_API_KEY": "secret-api-key"
        ])
        await service.refreshAvailability()

        guard case .unavailable(.notAuthenticated(let summary)) = service.status(for: .gemini) else {
            return XCTFail("Gemini should validate the higher-priority Vertex selection")
        }
        XCTAssertTrue(summary.contains("Vertex AI"))
        XCTAssertFalse(summary.contains("secret-api-key"))
    }

    func testComputeADCEnvironmentIsAccepted() async throws {
        let service = makeService(environment: [
            "GEMINI_CLI_USE_COMPUTE_ADC": "true"
        ])
        await service.refreshAvailability()

        let installation = try readyGeminiInstallation(from: service)
        XCTAssertEqual(installation.authSummary, "Application Default Credentials configured")
    }

    func testPersistedComputeADCSelectionDoesNotRequireInferenceFlag() async throws {
        let configDirectory = temporaryDirectory.appendingPathComponent(".gemini", isDirectory: true)
        try FileManager.default.createDirectory(
            at: configDirectory,
            withIntermediateDirectories: true
        )
        try #"{"security":{"auth":{"selectedType":"compute-default-credentials"}}}"#.write(
            to: configDirectory.appendingPathComponent("settings.json"),
            atomically: true,
            encoding: .utf8
        )

        let service = makeService(environment: [:])
        await service.refreshAvailability()

        let installation = try readyGeminiInstallation(from: service)
        XCTAssertEqual(installation.authSummary, "Application Default Credentials configured")
    }

    func testMissingGeminiAuthenticationFailsClosed() async {
        let service = makeService(environment: [:])
        await service.refreshAvailability()

        guard case .unavailable(.notAuthenticated(let summary)) = service.status(for: .gemini) else {
            return XCTFail("Gemini should require one of its supported authentication routes")
        }
        XCTAssertTrue(summary.contains("not configured"))
    }

    private func makeService(environment additions: [String: String]) -> AIProviderService {
        var environment = [
            "PATH": temporaryDirectory.path,
            "HOME": temporaryDirectory.path,
            "USER": "fixture",
            "LOGNAME": "fixture"
        ]
        environment.merge(additions) { _, new in new }
        let executablePath = geminiExecutable.path
        return AIProviderService(
            defaults: defaults,
            environmentLoader: { environment },
            homeDirectoryURL: temporaryDirectory,
            modelProvider: { provider in
                [AIModelOption(provider: provider, modelID: "fixture-model", isDefault: true)]
            },
            executableResolver: { name, _ in
                name == AIProvider.gemini.executableName ? executablePath : nil
            }
        )
    }

    private func readyGeminiInstallation(
        from service: AIProviderService,
        file: StaticString = #filePath,
        line: UInt = #line
    ) throws -> ProviderInstallation {
        guard case .ready(let installation) = service.status(for: .gemini) else {
            XCTFail("Gemini should be ready", file: file, line: line)
            throw TestFailure.notReady
        }
        return installation
    }

    private enum TestFailure: Error {
        case notReady
    }
}
