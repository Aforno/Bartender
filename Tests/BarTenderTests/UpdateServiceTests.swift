import XCTest
@testable import BarTender

final class UpdateServiceTests: XCTestCase {
    func testVersionComparisonOrdersPrereleasesAndFailsClosed() {
        let cases = [
            ("1.0.0-beta.1", "1.0.0", false),
            ("1.0.0", "1.0.0-beta.1", true),
            ("1.0.0-beta.2", "1.0.0-beta.1", true),
            ("1.0.0-rc.1", "1.0.0-beta.9", true),
            ("1.0.0-adhoc", "1.0.0", false),
            // Semver compares prerelease identifiers in ASCII order: "Beta" < "alpha".
            ("1.0.0-Beta", "1.0.0-alpha", false),
            ("1.0.0-alpha", "1.0.0-Beta", true),
            ("1..0", "1.0.0", false),
            ("release", "1.0.0", false),
            ("1.0.1", "Development", false)
        ]

        for (candidate, current, expected) in cases {
            XCTAssertEqual(UpdateService.isVersion(candidate, newerThan: current), expected, candidate)
        }
    }
}
