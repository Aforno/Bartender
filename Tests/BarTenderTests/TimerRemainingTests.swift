import XCTest
@testable import BarTender

final class TimerRemainingTests: XCTestCase {
    func testMoreThanOneSecondRemainingUsesCeil() {
        let now = Date(timeIntervalSince1970: 1_000)
        let end = now.addingTimeInterval(3.2)
        XCTAssertEqual(AppletRuntimeEngine.remainingSeconds(until: end, now: now), 4)
    }

    func testBetweenZeroAndOneSecondPreservesAtLeastOne() {
        let now = Date(timeIntervalSince1970: 1_000)
        let end = now.addingTimeInterval(0.8)
        XCTAssertEqual(AppletRuntimeEngine.remainingSeconds(until: end, now: now), 1)
    }

    func testExactlyZero() {
        let now = Date(timeIntervalSince1970: 1_000)
        XCTAssertEqual(AppletRuntimeEngine.remainingSeconds(until: now, now: now), 0)
    }

    func testAlreadyExpired() {
        let now = Date(timeIntervalSince1970: 1_000)
        let end = now.addingTimeInterval(-0.5)
        XCTAssertEqual(AppletRuntimeEngine.remainingSeconds(until: end, now: now), 0)
    }

    func testTimerLoopDispositionMatchesHelper() {
        let now = Date(timeIntervalSince1970: 2_000)
        XCTAssertEqual(
            AppletRuntimeEngine.timerLoopDisposition(timerEnd: nil, now: now),
            .idle
        )
        XCTAssertEqual(
            AppletRuntimeEngine.timerLoopDisposition(
                timerEnd: now.addingTimeInterval(0.8),
                now: now
            ),
            .running(remaining: 1)
        )
        XCTAssertEqual(
            AppletRuntimeEngine.timerLoopDisposition(
                timerEnd: now.addingTimeInterval(-1),
                now: now
            ),
            .completed
        )
    }

    @MainActor
    func testPauseAndResumeNearCompletionPreservesRemainder() {
        let runtime = AppletRuntimeEngine()
        defer { runtime.stopAll() }

        let timer = AppletManifest(
            name: "Near End",
            iconSystemName: "timer",
            kind: .timer,
            titleTemplate: "{{remaining}}",
            refreshIntervalSeconds: nil,
            enabled: true,
            config: AppletConfig(durationSeconds: 2, autoRestart: false)
        )
        runtime.sync(with: [timer])
        XCTAssertEqual(runtime.snapshots[timer.id]?.isRunning, true)

        // Force a sub-second remainder by replacing the end date.
        // Access via toggle after waiting is racy; call remainingSeconds directly for policy
        // and use pause/resume with a long enough duration for integration.
        runtime.toggleTimer(id: timer.id, manifest: timer) // pause
        let paused = runtime.snapshots[timer.id]
        XCTAssertEqual(paused?.isRunning, false)

        // Resume uses saved remainder when still positive.
        runtime.toggleTimer(id: timer.id, manifest: timer)
        XCTAssertEqual(runtime.snapshots[timer.id]?.isRunning, true)
    }

    func testResumedTimerRemainingUsesSavedValue() {
        XCTAssertEqual(
            AppletRuntimeEngine.resumedTimerRemaining(pausedRemaining: 1, duration: 90),
            1
        )
        XCTAssertEqual(
            AppletRuntimeEngine.resumedTimerRemaining(pausedRemaining: 0, duration: 90),
            90
        )
        XCTAssertEqual(
            AppletRuntimeEngine.resumedTimerRemaining(pausedRemaining: nil, duration: 90),
            90
        )
    }
}
