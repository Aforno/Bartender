import Foundation
import XCTest
@testable import BarTender

/// Drives `AppModel`'s banner auto-dismissal with a manually advanced clock,
/// standing in for the `BannerView` copies in the main and Settings windows.
@MainActor
final class BannerLifecycleTests: XCTestCase {
    private var temporaryDirectory: URL!
    private var defaults: UserDefaults!
    private var defaultsSuiteName: String!
    private var clock: ManualBannerClock!
    private var model: AppModel!

    override func setUpWithError() throws {
        temporaryDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("BarTender-BannerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: temporaryDirectory, withIntermediateDirectories: true)
        defaultsSuiteName = "BarTender.BannerTests.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: defaultsSuiteName)!
        clock = ManualBannerClock()
        model = AppModel(
            store: AppletStore(fileURL: temporaryDirectory.appendingPathComponent("applets.json")),
            preferences: AppPreferences(defaults: defaults),
            shellApprovals: ShellApprovalStore(defaults: defaults, storageKey: "approvals"),
            generatedTools: GeneratedToolArtifactStore(
                rootURL: temporaryDirectory.appendingPathComponent("artifacts", isDirectory: true)
            ),
            bannerDismissalDelay: .seconds(8),
            bannerStaleAfter: .seconds(300),
            bannerClock: clock.bannerClock
        )
    }

    override func tearDownWithError() throws {
        model.shutdown()
        model = nil
        defaults.removePersistentDomain(forName: defaultsSuiteName)
        try? FileManager.default.removeItem(at: temporaryDirectory)
    }

    func testInfoBannerDoesNotExpireWhileNoViewIsVisible() {
        model.bannerMessage = .info("Saved")

        clock.advance(by: .seconds(60))

        XCTAssertEqual(model.bannerMessage?.text, "Saved")
    }

    func testCountdownStartsWhenAViewBecomesVisible() {
        let banner = BannerMessage.info("Saved")
        model.bannerMessage = banner
        clock.advance(by: .seconds(30))

        show(UUID())
        clock.advance(by: .seconds(7))
        XCTAssertEqual(model.bannerMessage, banner)

        clock.advance(by: .seconds(1))
        XCTAssertNil(model.bannerMessage)
    }

    func testTimeWhileTheWindowIsHiddenDoesNotCount() {
        let view = UUID()
        model.bannerMessage = .info("Saved")
        show(view)
        clock.advance(by: .seconds(5))

        // Minimized, hidden, covered, or on another Space: still mounted, not visible.
        model.updateBannerView(view, visible: false, hovered: false)
        clock.advance(by: .seconds(60))
        XCTAssertNotNil(model.bannerMessage)

        show(view)
        clock.advance(by: .seconds(2))
        XCTAssertNotNil(model.bannerMessage)
        clock.advance(by: .seconds(1))
        XCTAssertNil(model.bannerMessage)
    }

    func testHoverPausesAndUnhoverResumesWithRemainingTime() {
        let view = UUID()
        model.bannerMessage = .info("Saved")
        show(view)
        clock.advance(by: .seconds(5))

        show(view, hovered: true)
        clock.advance(by: .seconds(60))
        XCTAssertNotNil(model.bannerMessage)

        show(view)
        clock.advance(by: .seconds(2))
        XCTAssertNotNil(model.bannerMessage)
        clock.advance(by: .seconds(1))
        XCTAssertNil(model.bannerMessage)
    }

    func testRemovingAHoveredViewDoesNotPauseForever() {
        let settings = UUID()
        model.bannerMessage = .info("Saved")
        show(settings, hovered: true)
        show(UUID())

        // The Settings window closes mid-hover; no hover-exit ever arrives.
        model.removeBannerView(settings)
        clock.advance(by: .seconds(8))

        XCTAssertNil(model.bannerMessage)
    }

    func testHoverOnAHiddenViewIsIgnored() {
        model.bannerMessage = .info("Saved")
        show(UUID())
        model.updateBannerView(UUID(), visible: false, hovered: true)

        clock.advance(by: .seconds(8))

        XCTAssertNil(model.bannerMessage)
    }

    func testMultipleVisibleViewsShareOneCountdown() {
        let main = UUID()
        let settings = UUID()
        model.bannerMessage = .info("Saved")
        show(main)
        clock.advance(by: .seconds(5))

        // Opening Settings neither restarts nor duplicates the countdown.
        show(settings)
        XCTAssertEqual(clock.pendingCount, 1)
        clock.advance(by: .seconds(3))
        XCTAssertNil(model.bannerMessage)

        // Hovering either copy pauses the shared countdown.
        model.bannerMessage = .info("Exported")
        show(settings, hovered: true)
        clock.advance(by: .seconds(60))
        XCTAssertEqual(model.bannerMessage?.text, "Exported")
    }

    func testUnseenInfoBannerIsDroppedAfterStaleWindow() {
        model.bannerMessage = .info("Saved")

        clock.advance(by: .seconds(299))
        XCTAssertNotNil(model.bannerMessage)
        clock.advance(by: .seconds(1))

        XCTAssertNil(model.bannerMessage)
    }

    func testStaleWindowOnlyCountsContinuousUnseenTime() {
        let view = UUID()
        model.bannerMessage = .info("Saved")
        clock.advance(by: .seconds(200))

        show(view, hovered: true)
        clock.advance(by: .seconds(200))
        XCTAssertNotNil(model.bannerMessage)

        model.removeBannerView(view)
        clock.advance(by: .seconds(299))
        XCTAssertNotNil(model.bannerMessage)
        clock.advance(by: .seconds(1))
        XCTAssertNil(model.bannerMessage)
    }

    func testErrorBannersStayUntilDismissed() {
        model.bannerMessage = .error("Could not export the library")
        clock.advance(by: .seconds(600))
        show(UUID())
        clock.advance(by: .seconds(600))

        XCTAssertEqual(model.bannerMessage?.text, "Could not export the library")
        XCTAssertEqual(clock.pendingCount, 0)

        model.bannerMessage = nil
        XCTAssertNil(model.bannerMessage)
    }

    func testReplacingABannerRestartsTheCountdown() {
        let view = UUID()
        model.bannerMessage = .info("First")
        show(view)
        clock.advance(by: .seconds(6))

        // The same view keeps rendering, now showing the replacement.
        let second = BannerMessage.info("Second")
        model.bannerMessage = second
        XCTAssertEqual(clock.pendingCount, 1)
        clock.advance(by: .seconds(7))
        XCTAssertEqual(model.bannerMessage, second)
        clock.advance(by: .seconds(1))
        XCTAssertNil(model.bannerMessage)
    }

    func testReplacingInfoWithErrorStopsTheCountdown() {
        model.bannerMessage = .info("Testing…")
        show(UUID())
        clock.advance(by: .seconds(6))

        model.bannerMessage = .error("Needs attention")
        clock.advance(by: .seconds(60))

        XCTAssertEqual(model.bannerMessage?.text, "Needs attention")
    }

    private func show(_ view: UUID, hovered: Bool = false) {
        model.updateBannerView(view, visible: true, hovered: hovered)
    }
}

/// A `BannerClock` whose time only moves when a test calls `advance(by:)`.
@MainActor
private final class ManualBannerClock {
    private struct Pending {
        let id: Int
        let fireAt: Duration
        let action: @MainActor () -> Void
    }

    private var now: Duration = .zero
    private var pending: [Pending] = []
    private var nextID = 0

    var pendingCount: Int { pending.count }

    var bannerClock: BannerClock {
        BannerClock(
            now: { [unowned self] in now },
            schedule: { [unowned self] delay, action in
                let id = nextID
                nextID += 1
                pending.append(Pending(id: id, fireAt: now + delay, action: action))
                return { [weak self] in self?.pending.removeAll { $0.id == id } }
            }
        )
    }

    /// Moves time forward, firing due actions in order at their scheduled time.
    func advance(by duration: Duration) {
        let target = now + duration
        while let next = pending.filter({ $0.fireAt <= target }).min(by: { $0.fireAt < $1.fireAt }) {
            pending.removeAll { $0.id == next.id }
            now = next.fireAt
            next.action()
        }
        now = target
    }
}
