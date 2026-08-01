import XCTest
@testable import BarTender

@MainActor
final class AppletRuntimeStateIsolationTests: XCTestCase {
    func testSyncRemovesAbsentSnapshotsAndStopAllClearsRuntimeState() {
        let runtime = AppletRuntimeEngine()
        let timer = timerManifest()
        defer { runtime.stopAll() }

        runtime.sync(with: [timer])

        XCTAssertEqual(runtime.snapshots[timer.id]?.isRunning, true)
        XCTAssertTrue(runtime.activeExecutionIDs.contains(timer.id))

        runtime.sync(with: [])

        XCTAssertNil(runtime.snapshots[timer.id])
        XCTAssertFalse(runtime.activeExecutionIDs.contains(timer.id))

        runtime.sync(with: [timer])
        XCTAssertFalse(runtime.snapshots.isEmpty)

        runtime.stopAll()

        XCTAssertTrue(runtime.snapshots.isEmpty)
        XCTAssertTrue(runtime.activeExecutionIDs.isEmpty)
    }

    func testDisabledTimerControlsDoNotMutateSnapshotOrStartExecution() {
        let runtime = AppletRuntimeEngine()
        let timer = timerManifest(enabled: false)
        defer { runtime.stopAll() }

        runtime.sync(with: [timer])
        let initial = runtime.snapshots[timer.id]

        runtime.toggleTimer(id: timer.id, manifest: timer)
        runtime.resetTimer(id: timer.id, manifest: timer)

        XCTAssertEqual(runtime.snapshots[timer.id], initial)
        XCTAssertEqual(runtime.snapshots[timer.id]?.isRunning, false)
        XCTAssertFalse(runtime.activeExecutionIDs.contains(timer.id))
    }

    func testPausedTimerHasNoLoopAndSyncDoesNotRestartIt() {
        let runtime = AppletRuntimeEngine()
        let timer = timerManifest()
        defer { runtime.stopAll() }

        runtime.sync(with: [timer])
        XCTAssertEqual(runtime.snapshots[timer.id]?.isRunning, true)
        XCTAssertTrue(runtime.activeExecutionIDs.contains(timer.id))

        runtime.toggleTimer(id: timer.id, manifest: timer)
        let paused = runtime.snapshots[timer.id]

        XCTAssertEqual(paused?.isRunning, false)
        XCTAssertFalse(runtime.activeExecutionIDs.contains(timer.id))

        runtime.sync(with: [timer])

        XCTAssertEqual(runtime.snapshots[timer.id], paused)
        XCTAssertFalse(runtime.activeExecutionIDs.contains(timer.id))

        runtime.toggleTimer(id: timer.id, manifest: timer)

        XCTAssertEqual(runtime.snapshots[timer.id]?.isRunning, true)
        XCTAssertTrue(runtime.activeExecutionIDs.contains(timer.id))
    }

    func testSameIDReplacementDoesNotRetainPreviousManifestSnapshot() {
        let runtime = AppletRuntimeEngine()
        let timer = timerManifest()
        var replacement = timer
        replacement.name = "Replacement Monitor"
        replacement.kind = .httpMonitor
        replacement.titleTemplate = "{{status}}"
        replacement.refreshIntervalSeconds = 60
        replacement.config = AppletConfig(url: "https://example.invalid")
        defer { runtime.stopAll() }

        runtime.sync(with: [timer])
        XCTAssertEqual(runtime.snapshots[timer.id]?.statusText, "Running")

        runtime.sync(with: [replacement])

        XCTAssertEqual(runtime.snapshots[replacement.id]?.statusText, "Idle")
        XCTAssertEqual(runtime.snapshots[replacement.id]?.title, replacement.name)
        XCTAssertEqual(runtime.snapshots[replacement.id]?.isRunning, false)
    }

    private func timerManifest(enabled: Bool = true) -> AppletManifest {
        AppletManifest(
            name: "Runtime Timer",
            iconSystemName: "timer",
            kind: .timer,
            titleTemplate: "{{remaining}}",
            refreshIntervalSeconds: nil,
            enabled: enabled,
            config: AppletConfig(durationSeconds: 90, autoRestart: false)
        )
    }
}
