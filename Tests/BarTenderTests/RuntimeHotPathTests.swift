import Combine
import Foundation
import XCTest
@testable import BarTender

final class RuntimeHotPathTests: XCTestCase {
    func testPublishedStateIgnoresUpdatedAt() {
        let first = AppletSnapshot(
            statusText: "Running",
            title: "24:59",
            detailLines: ["Duration 25:00", "Remaining 24:59"],
            isHealthy: true,
            values: ["remaining": "24:59", "status": "Running", "value": "24:59"],
            updatedAt: Date(timeIntervalSince1970: 1),
            isRunning: true,
            progress: 0.01
        )
        var second = first
        second.updatedAt = Date(timeIntervalSince1970: 2)
        XCTAssertTrue(first.hasSamePublishedState(as: second))

        second.title = "24:58"
        XCTAssertFalse(first.hasSamePublishedState(as: second))
    }

    func testTimerDisplaySleepMatchesWholeSecondQuantization() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(
            Double(AppletRuntimeEngine.nanosecondsUntilNextTimerDisplayChange(
                timerEnd: now.addingTimeInterval(3.2),
                now: now
            )),
            200_000_000,
            accuracy: 1_000
        )
        XCTAssertEqual(
            AppletRuntimeEngine.nanosecondsUntilNextTimerDisplayChange(
                timerEnd: now.addingTimeInterval(3.0),
                now: now
            ),
            1_000_000_000
        )
        XCTAssertEqual(
            Double(AppletRuntimeEngine.nanosecondsUntilNextTimerDisplayChange(
                timerEnd: now.addingTimeInterval(0.8),
                now: now
            )),
            800_000_000,
            accuracy: 1_000
        )
        XCTAssertEqual(
            AppletRuntimeEngine.nanosecondsUntilNextTimerDisplayChange(
                timerEnd: now.addingTimeInterval(-1),
                now: now
            ),
            0
        )
    }

    func testSharedSamplerReusesRecentSamplesAndSkipsUnrequestedMetrics() {
        let sampler = SharedSystemMetricsSampler()
        sampler.reuseWindow = 60
        _ = sampler.sample(cpu: true, memory: false)
        _ = sampler.sample(cpu: true, memory: false)
        XCTAssertEqual(sampler.cpuSampleCount, 1)
        XCTAssertEqual(sampler.memorySampleCount, 0)

        _ = sampler.sample(cpu: false, memory: true)
        XCTAssertEqual(sampler.cpuSampleCount, 1)
        XCTAssertEqual(sampler.memorySampleCount, 1)
        _ = sampler.sample(cpu: false, memory: true)
        XCTAssertEqual(sampler.memorySampleCount, 1)
    }

    func testSharedSamplerResetDropsCPUBaseline() {
        let sampler = SharedSystemMetricsSampler()
        sampler.reuseWindow = 0
        XCTAssertEqual(sampler.sample(cpu: true, memory: false).cpu, 0)
        _ = sampler.sample(cpu: true, memory: false)
        XCTAssertEqual(sampler.cpuSampleCount, 2)
        sampler.reset()
        XCTAssertEqual(sampler.cpuSampleCount, 0)
        XCTAssertEqual(sampler.sample(cpu: true, memory: false).cpu, 0)
        XCTAssertEqual(sampler.cpuSampleCount, 1)
    }

    @MainActor
    func testReenablingMetricsAppletsDropsCPUBaseline() async {
        SystemMetricsSampler.shared.reset()
        defer { SystemMetricsSampler.shared.reset() }
        let runtime = AppletRuntimeEngine()
        defer { runtime.stopAll() }
        var metrics = AppletManifest(
            name: "CPU",
            iconSystemName: "cpu",
            kind: .systemMetrics,
            titleTemplate: "{{cpu}}",
            refreshIntervalSeconds: 60,
            enabled: true,
            config: AppletConfig(metrics: [.cpu])
        )
        runtime.sync(with: [metrics])
        let firstDeadline = Date().addingTimeInterval(1)
        while Date() < firstDeadline, runtime.snapshots[metrics.id]?.values["cpu"] == nil {
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertNotNil(runtime.snapshots[metrics.id]?.values["cpu"])

        metrics.enabled = false
        runtime.sync(with: [metrics])
        await Self.drainMainQueue()

        metrics.enabled = true
        runtime.sync(with: [metrics])
        let restartDeadline = Date().addingTimeInterval(1)
        var cpu: String?
        while Date() < restartDeadline {
            cpu = runtime.snapshots[metrics.id]?.values["cpu"]
            if cpu == "0%" { break }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        XCTAssertEqual(cpu, "0%")
    }

    @MainActor
    func testUnchangedSnapshotsDoNotRepublish() async {
        let runtime = AppletRuntimeEngine()
        defer { runtime.stopAll() }
        let timer = AppletManifest(
            name: "Idle Timer",
            iconSystemName: "timer",
            kind: .timer,
            titleTemplate: "{{remaining}}",
            enabled: false,
            config: AppletConfig(durationSeconds: 90)
        )
        runtime.sync(with: [timer])
        await Self.drainMainQueue()
        let firstUpdatedAt = runtime.snapshots[timer.id]?.updatedAt

        var publishes = 0
        let subscription = runtime.snapshotsPublisher.sink { _ in publishes += 1 }
        runtime.sync(with: [timer])
        await Self.drainMainQueue()

        XCTAssertEqual(publishes, 0)
        XCTAssertEqual(runtime.snapshots[timer.id]?.updatedAt, firstUpdatedAt)
        _ = subscription
    }

    @MainActor
    func testMultipleSnapshotMutationsCoalesceToOnePublish() async {
        let runtime = AppletRuntimeEngine()
        defer { runtime.stopAll() }
        let first = AppletManifest(
            name: "One",
            iconSystemName: "timer",
            kind: .timer,
            titleTemplate: "{{remaining}}",
            enabled: false,
            config: AppletConfig(durationSeconds: 30)
        )
        var second = first
        second.id = UUID()
        second.name = "Two"
        runtime.sync(with: [first, second])
        await Self.drainMainQueue()

        var publishes = 0
        let subscription = runtime.snapshotsPublisher.sink { _ in publishes += 1 }
        runtime.sync(with: [])
        await Self.drainMainQueue()

        XCTAssertEqual(publishes, 1)
        XCTAssertTrue(runtime.snapshots.isEmpty)
        _ = subscription
    }

    @MainActor
    func testStatusItemRefreshIdentityChangesWithTitleAndRunState() {
        let applet = AppletManifest(
            name: "Load",
            iconSystemName: "cpu",
            kind: .systemMetrics,
            titleTemplate: "{{cpu}}",
            config: AppletConfig(metrics: [.cpu])
        )
        let snapshot = AppletSnapshot.placeholder(for: applet)
        let idle = StatusItemManager.refreshIdentity(
            applet: applet,
            snapshot: snapshot,
            runState: .idle,
            showsLiveTitle: true
        )
        var running = idle
        running.runState = .running
        XCTAssertNotEqual(idle, running)

        var titled = idle
        titled.title = "12%"
        XCTAssertNotEqual(idle, titled)

        XCTAssertEqual(
            idle,
            StatusItemManager.refreshIdentity(
                applet: applet,
                snapshot: snapshot,
                runState: .idle,
                showsLiveTitle: true
            )
        )
    }

    func testPrepareApprovedExecutionDoesNotRewriteUnchangedRevision() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTender-PrepareCache-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }
        let source = """
        #!/bin/zsh
        printf '%s\\n' '{"title":"OK","status":"OK","details":[],"healthy":true,"values":{}}'
        """
        let manifest = AppletManifest(
            name: "Cached Tool",
            iconSystemName: "hammer",
            kind: .generatedTool,
            titleTemplate: "{{value}}",
            config: AppletConfig(generatedSource: source)
        )
        let artifacts = GeneratedToolArtifactStore(rootURL: root)
        _ = try artifacts.install(manifest)
        let first = try artifacts.prepareApprovedExecution(manifest)
        let firstModified = try FileManager.default.attributesOfItem(atPath: first.path)[.modificationDate] as? Date
        let second = try artifacts.prepareApprovedExecution(manifest)
        let secondModified = try FileManager.default.attributesOfItem(atPath: second.path)[.modificationDate] as? Date

        XCTAssertEqual(first, second)
        XCTAssertEqual(firstModified, secondModified)
        try artifacts.validateApprovedExecution(manifest, executable: second)
    }

    func testFailureNotificationsAreEdgeTriggeredAndResetAfterRecovery() {
        let id = UUID()
        var tracker = FailureTransitionTracker()

        XCTAssertTrue(tracker.record(id: id, healthy: false))
        XCTAssertFalse(tracker.record(id: id, healthy: false))
        XCTAssertFalse(tracker.record(id: id, healthy: true))
        XCTAssertTrue(tracker.record(id: id, healthy: false))
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

    private static func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async {
                continuation.resume()
            }
        }
    }
}
