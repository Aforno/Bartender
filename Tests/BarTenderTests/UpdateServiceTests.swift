import XCTest
@testable import BarTender

final class UpdateServiceTests: XCTestCase {
    func testSemanticPrereleaseOrdering() {
        XCTAssertFalse(UpdateService.isVersion("1.0.0-beta.1", newerThan: "1.0.0"))
        XCTAssertTrue(UpdateService.isVersion("1.0.0", newerThan: "1.0.0-beta.1"))
        XCTAssertTrue(UpdateService.isVersion("1.0.0-beta.2", newerThan: "1.0.0-beta.1"))
        XCTAssertTrue(UpdateService.isVersion("1.0.0-rc.1", newerThan: "1.0.0-beta.9"))
        XCTAssertFalse(UpdateService.isVersion("1.0.0-adhoc", newerThan: "1.0.0"))
    }

    func testMalformedVersionsFailClosed() {
        XCTAssertFalse(UpdateService.isVersion("1..0", newerThan: "1.0.0"))
        XCTAssertFalse(UpdateService.isVersion("release", newerThan: "1.0.0"))
        XCTAssertFalse(UpdateService.isVersion("1.0.1", newerThan: "Development"))
    }
}
