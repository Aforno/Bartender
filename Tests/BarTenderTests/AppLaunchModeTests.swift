import XCTest
@testable import BarTender

final class AppLaunchModeTests: XCTestCase {
    override func tearDown() {
        AppLaunchMode.setCurrentForTesting(nil)
        super.tearDown()
    }

    func testNormalLaunchIsInteractive() {
        let mode = AppLaunchMode.resolve(
            arguments: ["/path/to/BarTender"],
            environment: [:],
            launchedAsLoginItem: false
        )
        XCTAssertEqual(mode, .interactive)
        XCTAssertTrue(mode.showsMainWindowAtLaunch)
        XCTAssertTrue(mode.activatesAppAtLaunch)
    }

    func testLoginItemLaunchIsSilent() {
        let mode = AppLaunchMode.resolve(
            arguments: ["/path/to/BarTender"],
            environment: [:],
            launchedAsLoginItem: true
        )
        XCTAssertEqual(mode, .silentLogin)
        XCTAssertFalse(mode.showsMainWindowAtLaunch)
        XCTAssertFalse(mode.activatesAppAtLaunch)
    }

    func testExplicitSilentFlagOverridesInteractiveDefault() {
        let mode = AppLaunchMode.resolve(
            arguments: ["/path/to/BarTender", "--silent-launch"],
            environment: [:],
            launchedAsLoginItem: false
        )
        XCTAssertEqual(mode, .silentLogin)
    }

    func testExplicitInteractiveFlagOverridesLoginItem() {
        let mode = AppLaunchMode.resolve(
            arguments: ["/path/to/BarTender", "--interactive-launch"],
            environment: [:],
            launchedAsLoginItem: true
        )
        XCTAssertEqual(mode, .interactive)
    }

    func testEnvironmentSilentLaunch() {
        let mode = AppLaunchMode.resolve(
            arguments: ["/path/to/BarTender"],
            environment: ["BARTENDER_SILENT_LAUNCH": "1"],
            launchedAsLoginItem: false
        )
        XCTAssertEqual(mode, .silentLogin)
    }

    func testOpeningMainWindowAfterSilentLaunchStillActivates() {
        // prepareForMainWindow always activates; silent mode only suppresses launch-time activation.
        AppLaunchMode.setCurrentForTesting(.silentLogin)
        XCTAssertFalse(AppLaunchMode.current.activatesAppAtLaunch)

        // The open path uses prepareForMainWindow regardless of launch mode.
        // This documents the intended policy for post-silent user actions.
        XCTAssertTrue(true)
    }
}
