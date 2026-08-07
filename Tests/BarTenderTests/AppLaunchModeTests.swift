import AppKit
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

    func testDetectLaunchedAsLoginItemRecognizesPlatformKeyword() {
        let event = Self.makeOpenApplicationEvent()
        event.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: keyAELaunchedAsLogInItem)

        XCTAssertTrue(AppLaunchMode.detectLaunchedAsLoginItem(appleEvent: event))
    }

    func testDetectLaunchedAsLoginItemReturnsFalseWhenParameterAbsent() {
        let event = Self.makeOpenApplicationEvent()

        XCTAssertFalse(AppLaunchMode.detectLaunchedAsLoginItem(appleEvent: event))
    }

    func testDetectLaunchedAsLoginItemRecognizesServiceItemKeyword() {
        let event = Self.makeOpenApplicationEvent()
        event.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: keyAELaunchedAsServiceItem)

        XCTAssertTrue(AppLaunchMode.detectLaunchedAsLoginItem(appleEvent: event))
    }

    func testDetectLaunchedAsLoginItemIgnoresLegacyWrongFourCharCode() {
        // Regression guard: an earlier build checked `'lili'` (0x6C696C69)
        // instead of the platform `'lgit'` constant. That keyword must not be
        // treated as a login-item launch signal.
        let wrongLegacyKeyword = AEKeyword(UInt32(bitPattern: Int32(0x6C696C69)))
        let event = Self.makeOpenApplicationEvent()
        event.setParam(NSAppleEventDescriptor(boolean: true), forKeyword: wrongLegacyKeyword)

        XCTAssertFalse(AppLaunchMode.detectLaunchedAsLoginItem(appleEvent: event))
    }

    func testDetectLaunchedAsLoginItemReturnsFalseForNilEvent() {
        XCTAssertFalse(AppLaunchMode.detectLaunchedAsLoginItem(appleEvent: nil))
    }

    @MainActor
    func testOpeningMainWindowAfterSilentLaunchUsesStoredSwiftUIAction() {
        AppLaunchMode.setCurrentForTesting(.silentLogin)
        AppActions.shared.resetForTesting()
        defer { AppActions.shared.resetForTesting() }

        var openCount = 0
        AppActions.shared.installOpenWindowAction {
            openCount += 1
        }

        XCTAssertFalse(AppLaunchMode.current.activatesAppAtLaunch)
        AppActions.shared.openMainWindow()
        XCTAssertEqual(openCount, 1)
    }

    // MARK: - Helpers

    private static func makeOpenApplicationEvent() -> NSAppleEventDescriptor {
        NSAppleEventDescriptor(
            eventClass: AEEventClass(kCoreEventClass),
            eventID: AEEventID(kAEOpenApplication),
            targetDescriptor: nil,
            returnID: AEReturnID(kAutoGenerateReturnID),
            transactionID: AETransactionID(kAnyTransactionID)
        )
    }
}
