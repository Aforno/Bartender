import Foundation
import XCTest
@testable import BarTender

final class ManifestValidatorTests: XCTestCase {
    func testNormalizesWhitespaceAndAppliesDefaultRefresh() throws {
        let draft = CodexAppletDraft(
            name: "  Site  ",
            iconSystemName: "  globe  ",
            kind: .httpMonitor,
            titleTemplate: "  {{status}}  ",
            refreshIntervalSeconds: nil,
            notifyOnComplete: nil,
            notifyOnFailure: nil,
            config: AppletConfig(url: "  https://example.com/health  ", timeoutSeconds: 5)
        )

        let manifest = try ManifestValidator.makeManifest(from: draft, sourcePrompt: "  monitor it  ")

        XCTAssertEqual(manifest.name, "Site")
        XCTAssertEqual(manifest.iconSystemName, "globe")
        XCTAssertEqual(manifest.titleTemplate, "{{status}}")
        XCTAssertEqual(manifest.sourcePrompt, "monitor it")
        XCTAssertEqual(manifest.config.url, "https://example.com/health")
        XCTAssertEqual(manifest.refreshIntervalSeconds, AppletKind.httpMonitor.defaultRefreshInterval)
    }

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

    func testBundledSchemaMatchesValidatorLimitsAndExcludesApproval() throws {
        let schema = try ManifestGenerationSupport.schemaJSONString()
        let data = try XCTUnwrap(schema.data(using: .utf8))
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let properties = try XCTUnwrap(root["properties"] as? [String: Any])
        let name = try XCTUnwrap(properties["name"] as? [String: Any])
        let refresh = try XCTUnwrap(properties["refreshIntervalSeconds"] as? [String: Any])
        let config = try XCTUnwrap(properties["config"] as? [String: Any])
        let configProperties = try XCTUnwrap(config["properties"] as? [String: Any])

        XCTAssertEqual(name["maxLength"] as? Int, ManifestLimits.nameLength)
        XCTAssertEqual(refresh["minimum"] as? Double, ManifestLimits.refreshInterval.lowerBound)
        XCTAssertEqual(refresh["maximum"] as? Double, ManifestLimits.refreshInterval.upperBound)
        XCTAssertNil(configProperties["shellApproved"])
        XCTAssertEqual((configProperties["port"] as? [String: Any])?["maximum"] as? Int, ManifestLimits.port.upperBound)
        XCTAssertEqual(
            (configProperties["generatedSource"] as? [String: Any])?["maxLength"] as? Int,
            ManifestLimits.generatedSourceLength
        )
        let kind = try XCTUnwrap(properties["kind"] as? [String: Any])
        XCTAssertTrue((kind["enum"] as? [String])?.contains("generatedTool") == true)
    }

    func testGeneratedToolRequiresDedicatedExecutableSource() throws {
        let source = """
        #!/bin/zsh
        printf '%s\\n' '{"title":"Hi","status":"Ready","details":[],"healthy":true,"values":{"value":"Hi"}}'
        """
        let draft = CodexAppletDraft(
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
