import Foundation
import XCTest
@testable import BarTender

final class ManifestValidatorTests: XCTestCase {
    func testRejectsHTTPURLWithoutHost() {
        let manifest = makeManifest(
            kind: .httpMonitor,
            config: AppletConfig(url: "http:relative")
        )

        XCTAssertThrowsError(try ManifestValidator.validate(manifest)) { error in
            XCTAssertEqual(error as? ManifestValidationError, .invalidURL)
        }
    }

    func testRejectsInvalidStatusTimeoutAndDuplicateMetrics() {
        XCTAssertThrowsError(try ManifestValidator.validate(makeManifest(
            kind: .httpMonitor,
            config: AppletConfig(url: "https://example.com", expectedStatusCode: 99)
        ))) { error in
            XCTAssertEqual(error as? ManifestValidationError, .invalidExpectedStatusCode)
        }

        XCTAssertThrowsError(try ManifestValidator.validate(makeManifest(
            kind: .portMonitor,
            config: AppletConfig(timeoutSeconds: 0.1, host: "localhost", port: 80)
        ))) { error in
            XCTAssertEqual(error as? ManifestValidationError, .invalidTimeout)
        }

        XCTAssertThrowsError(try ManifestValidator.validate(makeManifest(
            kind: .systemMetrics,
            config: AppletConfig(metrics: [.cpu, .cpu])
        ))) { error in
            XCTAssertEqual(error as? ManifestValidationError, .duplicateMetrics)
        }
    }

    func testRejectsConfigForAnotherKind() {
        let manifest = makeManifest(
            kind: .timer,
            config: AppletConfig(durationSeconds: 60, url: "https://example.com")
        )

        XCTAssertThrowsError(try ManifestValidator.validate(manifest)) { error in
            guard case .configMismatch = error as? ManifestValidationError else {
                return XCTFail("Expected configMismatch, got \(error)")
            }
        }
    }

    func testGeneratedToolRequiresDedicatedExecutableSource() throws {
        let source = """
        #!/bin/zsh
        printf '%s\\n' '{"title":"Hi","status":"Ready","details":[],"healthy":true,"values":{"value":"Hi"}}'
        """
        let draft = AppletDraft(
            name: "Greeting",
            iconSystemName: "hand.wave",
            kind: .generatedTool,
            titleTemplate: "{{value}}",
            refreshIntervalSeconds: 20,
            notifyOnComplete: false,
            notifyOnFailure: true,
            config: AppletConfig(timeoutSeconds: 5, generatedSource: source)
        )

        let manifest = try ManifestValidator.makeManifest(from: draft, sourcePrompt: "say hello")

        XCTAssertEqual(manifest.kind, .generatedTool)
        XCTAssertEqual(manifest.config.generatedSource, source)
        XCTAssertThrowsError(try ManifestValidator.validate(makeManifest(
            kind: .generatedTool,
            config: AppletConfig(generatedSource: "echo not-an-executable")
        )))
    }

    func testGeneratedToolTimeoutMatchesEnforcedExecutionRange() throws {
        let source = "#!/bin/zsh\nprintf '%s\\n' '{\"title\":\"OK\",\"status\":\"OK\",\"details\":[],\"healthy\":true}'"

        XCTAssertThrowsError(try ManifestValidator.validate(makeManifest(
            kind: .generatedTool,
            config: AppletConfig(timeoutSeconds: 45, generatedSource: source)
        ))) { error in
            XCTAssertEqual(error as? ManifestValidationError, .invalidTimeout)
        }

        XCTAssertThrowsError(try ManifestValidator.validate(makeManifest(
            kind: .generatedTool,
            config: AppletConfig(timeoutSeconds: 0.5, generatedSource: source)
        ))) { error in
            XCTAssertEqual(error as? ManifestValidationError, .invalidTimeout)
        }

        XCTAssertNoThrow(try ManifestValidator.validate(makeManifest(
            kind: .generatedTool,
            config: AppletConfig(timeoutSeconds: 30, generatedSource: source)
        )))
    }

    func testRejectsNULInShellCommandAndWorkingDirectory() {
        XCTAssertThrowsError(try ManifestValidator.validate(makeManifest(
            kind: .shellCommand,
            config: AppletConfig(command: "echo safe\u{0}extra")
        ))) { error in
            guard case .configMismatch = error as? ManifestValidationError else {
                return XCTFail("Expected configMismatch, got \(error)")
            }
        }

        XCTAssertThrowsError(try ManifestValidator.validate(makeManifest(
            kind: .shellCommand,
            config: AppletConfig(command: "echo safe", workingDirectory: "/tmp\u{0}/evil")
        ))) { error in
            guard case .configMismatch = error as? ManifestValidationError else {
                return XCTFail("Expected configMismatch, got \(error)")
            }
        }
    }

    func testTimerRefreshIntervalIsStrippedBecauseTimersNeverPoll() throws {
        let timer = AppletManifest(
            name: "Timer",
            iconSystemName: "timer",
            kind: .timer,
            titleTemplate: "{{remaining}}",
            refreshIntervalSeconds: 5,
            config: AppletConfig(durationSeconds: 60)
        )

        let normalized = try ManifestValidator.normalizedAndValidated(timer)
        XCTAssertNil(normalized.refreshIntervalSeconds)

        let draft = AppletDraft(
            name: "Timer",
            iconSystemName: "timer",
            kind: .countdown,
            titleTemplate: "{{remaining}}",
            refreshIntervalSeconds: 10,
            notifyOnComplete: nil,
            notifyOnFailure: nil,
            config: AppletConfig(durationSeconds: 60)
        )
        let manifest = try ManifestValidator.makeManifest(from: draft, sourcePrompt: "count down")
        XCTAssertNil(manifest.refreshIntervalSeconds)
    }

    private func makeManifest(kind: AppletKind, config: AppletConfig) -> AppletManifest {
        AppletManifest(
            name: "Test",
            iconSystemName: kind.defaultIcon,
            kind: kind,
            titleTemplate: "{{status}}",
            refreshIntervalSeconds: kind.defaultRefreshInterval,
            config: config
        )
    }
}
