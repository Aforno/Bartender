import XCTest
@testable import BarTender

final class ManagerPopoverSizingTests: XCTestCase {
    func testCompactDefaultIsPreservedAsMinimum() {
        let size = ManagerPopoverSizing.contentSize(fitting: CGSize(width: 200, height: 40))
        XCTAssertEqual(size.width, ManagerPopoverSizing.minimumWidth)
        XCTAssertEqual(size.height, ManagerPopoverSizing.minimumHeight)
    }

    func testExpandsWithContent() {
        let size = ManagerPopoverSizing.contentSize(fitting: CGSize(width: 360, height: 120))
        XCTAssertEqual(size.width, 360)
        XCTAssertEqual(size.height, 120)
    }

    func testShrinksBackTowardMinimum() {
        let large = ManagerPopoverSizing.contentSize(fitting: CGSize(width: 360, height: 200))
        let small = ManagerPopoverSizing.contentSize(fitting: CGSize(width: 360, height: 50))
        XCTAssertGreaterThan(large.height, small.height)
        XCTAssertEqual(small.height, 50)
    }

    func testMaximumWidthAndHeightAreEnforced() {
        let size = ManagerPopoverSizing.contentSize(fitting: CGSize(width: 900, height: 900))
        XCTAssertEqual(size.width, ManagerPopoverSizing.maximumWidth)
        XCTAssertEqual(size.height, ManagerPopoverSizing.maximumHeight)
    }

    func testScreenHeightCapsLongErrors() {
        let size = ManagerPopoverSizing.contentSize(
            fitting: CGSize(width: 360, height: 500),
            screenVisibleHeight: 400
        )
        // 45% of 400 = 180
        XCTAssertEqual(size.height, 180, accuracy: 0.5)
    }

    func testDiagnosticsValidationDetectsMissingInfrastructure() {
        let snapshot = MenuBarDiagnosticsSnapshot(
            bootstrapCompleted: false,
            managerStatusItemInstalled: false,
            managerItemCount: 0,
            appletStatusItemManagerAttached: false,
            enabledAppletCount: 1,
            managedAppletItemCount: 0,
            appletItems: [
                .init(appletID: "x", name: "Clock", titleNonEmpty: false, titlePreview: "")
            ],
            managerHasVisibleTitleOrImage: false
        )
        let failures = snapshot.validationFailures(requireEnabledApplet: true)
        XCTAssertTrue(failures.contains(where: { $0.contains("bootstrap") }))
        XCTAssertTrue(failures.contains(where: { $0.contains("manager status item") }))
        XCTAssertTrue(failures.contains(where: { $0.contains("no managed status item") }))
        XCTAssertTrue(failures.contains(where: { $0.contains("title unexpectedly empty") }))
    }

    func testHealthyDiagnosticsPass() {
        let snapshot = MenuBarDiagnosticsSnapshot(
            bootstrapCompleted: true,
            managerStatusItemInstalled: true,
            managerItemCount: 1,
            appletStatusItemManagerAttached: true,
            enabledAppletCount: 1,
            managedAppletItemCount: 1,
            appletItems: [
                .init(appletID: "x", name: "Clock", titleNonEmpty: true, titlePreview: "12:00")
            ],
            managerHasVisibleTitleOrImage: true
        )
        XCTAssertTrue(snapshot.validationFailures(requireEnabledApplet: true).isEmpty)
    }
}
