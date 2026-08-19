import Foundation
import XCTest
@testable import BarTender

final class HTTPProbeTests: XCTestCase {
    func testRejectsNonHTTPSchemesAndMissingHosts() {
        XCTAssertNil(HTTPProbe.validatedRequestURL("file:///tmp/secret"))
        XCTAssertNil(HTTPProbe.validatedRequestURL("http:relative"))
        XCTAssertNil(HTTPProbe.validatedRequestURL("not a url"))
        XCTAssertNotNil(HTTPProbe.validatedRequestURL("https://example.com/status"))
        XCTAssertNotNil(HTTPProbe.validatedRequestURL("http://127.0.0.1:8080/health"))
    }

    func testDefaultHealthRequires2xxUnlessAnExactStatusIsConfigured() {
        XCTAssertTrue(HTTPProbe.isHealthy(statusCode: 200, expectedStatusCode: nil))
        XCTAssertTrue(HTTPProbe.isHealthy(statusCode: 204, expectedStatusCode: nil))
        XCTAssertFalse(HTTPProbe.isHealthy(statusCode: 301, expectedStatusCode: nil))
        XCTAssertFalse(HTTPProbe.isHealthy(statusCode: 404, expectedStatusCode: nil))
        XCTAssertTrue(HTTPProbe.isHealthy(statusCode: 301, expectedStatusCode: 301))
        XCTAssertFalse(HTTPProbe.isHealthy(statusCode: 200, expectedStatusCode: 204))
    }

    func testDisplayedURLsStripUserinfo() {
        let url = URL(string: "https://user:secret@example.com/path?q=1")!
        XCTAssertEqual(
            HTTPProbe.sanitizedDisplayString(for: url),
            "https://example.com/path?q=1"
        )
        XCTAssertEqual(
            HTTPProbe.sanitizedDisplayString(from: "https://token@status.example/health"),
            "https://status.example/health"
        )
    }
}
