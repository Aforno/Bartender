import XCTest
@testable import BarTender

final class GitStatusProbeTests: XCTestCase {
    func testGitInvocationDisablesFsmonitorHelpers() {
        let arguments = GitStatusProbe.invocationArguments(
            repositoryPath: "/tmp/repo",
            command: ["status", "--porcelain"]
        )
        XCTAssertEqual(
            arguments,
            [
                "-c", "core.fsmonitor=",
                "-c", "core.useBuiltinFSMonitor=false",
                "-C", "/tmp/repo",
                "status", "--porcelain"
            ]
        )
    }
}
