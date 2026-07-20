import XCTest
@testable import BarTender

final class RuntimeRegressionTests: XCTestCase {
    func testFailureNotificationsAreEdgeTriggeredAndResetAfterRecovery() {
        let id = UUID()
        var tracker = FailureTransitionTracker()

        XCTAssertTrue(tracker.record(id: id, healthy: false))
        XCTAssertFalse(tracker.record(id: id, healthy: false))
        XCTAssertFalse(tracker.record(id: id, healthy: true))
        XCTAssertTrue(tracker.record(id: id, healthy: false))
    }

    func testCompletedTimerRestartsFromConfiguredDuration() async {
        let remaining = await MainActor.run {
            AppletRuntimeEngine.resumedTimerRemaining(pausedRemaining: 0, duration: 90)
        }
        XCTAssertEqual(remaining, 90)
    }

    func testInvalidPortIsRejectedWithoutIntegerConversionTrap() async {
        let tooHigh = await PortProbe.isOpen(host: "localhost", port: 70000, timeout: 0.1)
        let negative = await PortProbe.isOpen(host: "localhost", port: -1, timeout: 0.1)
        XCTAssertFalse(tooHigh)
        XCTAssertFalse(negative)
    }

    func testCPUUsageCalculationAndIndependentCollectors() {
        XCTAssertEqual(
            SystemMetricsCollector.cpuUsagePercent(
                previous: [100, 100, 100, 0],
                current: [150, 150, 200, 0]
            ),
            50,
            accuracy: 0.001
        )

        let first = SystemMetricsCollector()
        let second = SystemMetricsCollector()
        XCTAssertEqual(first.cpuUsagePercent(), 0)
        XCTAssertEqual(second.cpuUsagePercent(), 0)
    }

    func testGeneratedToolInstallsAndProducesStructuredMenuOutput() async throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTenderGeneratedToolTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = """
        #!/bin/zsh
        printf '%s\\n' '{"title":"Custom 42","status":"Everything is ready","details":["Unique implementation"],"healthy":true,"values":{"value":"42"}}'
        """
        let manifest = AppletManifest(
            name: "Custom Tool",
            iconSystemName: "wand.and.sparkles",
            kind: .generatedTool,
            titleTemplate: "{{value}}",
            refreshIntervalSeconds: 30,
            config: AppletConfig(timeoutSeconds: 5, generatedSource: source)
        )
        let artifacts = GeneratedToolArtifactStore(rootURL: root)

        let result = await GeneratedToolRunner.run(
            manifest: manifest,
            approved: true,
            artifactStore: artifacts
        )

        XCTAssertEqual(result.output?.title, "Custom 42")
        XCTAssertEqual(result.output?.values["value"], "42")
        XCTAssertTrue(FileManager.default.isExecutableFile(
            atPath: root
                .appendingPathComponent(manifest.id.uuidString)
                .appendingPathComponent("tool.zsh").path
        ))
    }

    func testGeneratedToolIsInstalledButNotExecutedBeforeApproval() async {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTenderGeneratedToolTests-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let manifest = AppletManifest(
            name: "Guarded Tool",
            iconSystemName: "lock",
            kind: .generatedTool,
            titleTemplate: "{{value}}",
            config: AppletConfig(generatedSource: "#!/bin/zsh\nexit 9")
        )

        let result = await GeneratedToolRunner.run(
            manifest: manifest,
            approved: false,
            artifactStore: GeneratedToolArtifactStore(rootURL: root)
        )

        XCTAssertNil(result.output)
        XCTAssertFalse(result.approved)
        XCTAssertTrue(result.message.contains("review and allow"))
    }

    func testToolRunStateDoesNotCallUnhealthyOutputLive() {
        let manifest = AppletManifest(
            name: "Sensor",
            iconSystemName: "sensor",
            kind: .generatedTool,
            titleTemplate: "{{value}}",
            config: AppletConfig(generatedSource: "#!/bin/zsh\nexit 0")
        )
        let unhealthy = AppletSnapshot(
            statusText: "Unavailable",
            title: "Sensor",
            detailLines: [],
            isHealthy: false,
            values: [:],
            updatedAt: .now,
            isRunning: true,
            progress: nil
        )

        XCTAssertEqual(
            ToolRunState.resolve(manifest: manifest, snapshot: unhealthy, executionApproved: true),
            .needsAttention
        )
        XCTAssertEqual(
            ToolRunState.resolve(manifest: manifest, snapshot: unhealthy, executionApproved: false),
            .reviewRequired
        )
    }

    func testGeneratedSourceValidatorRejectsInvalidAndPrivilegedPrograms() async {
        let invalid = AppletManifest(
            name: "Invalid",
            iconSystemName: "xmark",
            kind: .generatedTool,
            titleTemplate: "{{value}}",
            config: AppletConfig(generatedSource: "#!/bin/zsh\nif true; then")
        )
        let privileged = AppletManifest(
            name: "Privileged",
            iconSystemName: "lock",
            kind: .generatedTool,
            titleTemplate: "{{value}}",
            config: AppletConfig(generatedSource: "#!/bin/zsh\n/usr/bin/powermetrics -n 1")
        )

        do {
            try await GeneratedToolSourceValidator.validate(invalid)
            XCTFail("Expected invalid syntax to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("syntax validation"))
        }

        do {
            try await GeneratedToolSourceValidator.validate(privileged)
            XCTFail("Expected privileged source to be rejected")
        } catch {
            XCTAssertTrue(error.localizedDescription.contains("administrator-only"))
        }
    }
}
