import XCTest
@testable import BarTender

final class PortProbeTests: XCTestCase {
    func testPortProbeCancelsTheConnectionWhenTheTaskIsCancelled() async {
        let task = Task {
            await PortProbe.isOpen(host: "192.0.2.1", port: 81, timeout: 8)
        }
        try? await Task.sleep(nanoseconds: 80_000_000)
        let started = Date()
        task.cancel()
        _ = await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 2)
    }

    func testInvalidPortIsRejectedWithoutIntegerConversionTrap() async {
        let tooHigh = await PortProbe.isOpen(host: "localhost", port: 70000, timeout: 0.1)
        let negative = await PortProbe.isOpen(host: "localhost", port: -1, timeout: 0.1)
        XCTAssertFalse(tooHigh)
        XCTAssertFalse(negative)
    }
}
