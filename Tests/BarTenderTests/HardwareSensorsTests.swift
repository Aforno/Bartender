import Foundation
import XCTest
@testable import BarTender

final class HardwareSensorsTests: XCTestCase {
    // MARK: - Value decoding

    func testDecodesLittleEndianFloat() throws {
        // 45.5 °C as a little-endian Float32.
        var value: Float = 45.5
        let bytes = withUnsafeBytes(of: &value) { Array($0) }
        let decoded = try XCTUnwrap(HardwareSensors.decodeValue(type: "flt ", bytes: bytes))
        XCTAssertEqual(decoded, 45.5, accuracy: 0.001)
    }

    func testDecodesBigEndianFixedPoint() throws {
        // sp78: signed 7.8 fixed point, big-endian. 45.0 * 256 = 11520 = 0x2D00.
        let sp78 = try XCTUnwrap(HardwareSensors.decodeValue(type: "sp78", bytes: [0x2D, 0x00]))
        XCTAssertEqual(sp78, 45.0, accuracy: 0.001)
        // sp4b: 11 fraction bits (4 integer bits, so values stay under 16).
        // 12.5 * 2048 = 25600 = 0x6400.
        let sp4b = try XCTUnwrap(HardwareSensors.decodeValue(type: "sp4b", bytes: [0x64, 0x00]))
        XCTAssertEqual(sp4b, 12.5, accuracy: 0.001)
    }

    func testRejectsUndecodablePayloads() {
        XCTAssertNil(HardwareSensors.decodeValue(type: "flt ", bytes: [0x00, 0x01]))
        XCTAssertNil(HardwareSensors.decodeValue(type: "ui8 ", bytes: [0x2D]))
        XCTAssertNil(HardwareSensors.decodeValue(type: "sp78", bytes: [0x2D]))
    }

    // MARK: - Classification

    func testClassifiesRepresentativeSMCKeys() {
        let cases: [(String, SensorGroup)] = [
            ("Tp09", .cpu), ("TG0P", .gpu), ("Te05", .soc),
            ("TB1T", .battery), ("TA0P", .ambient), ("Tm0B", .memory),
            ("Ts0P", .storage), ("TVM1", .other), ("Tp", .other)
        ]

        for (key, expected) in cases {
            XCTAssertEqual(SensorGroup.classify(smcKey: key), expected, key)
        }
    }

    // MARK: - Aggregation and reports

    private func sampleReadings() -> [SensorReading] {
        [
            SensorReading(key: "Tp00", group: .cpu, celsius: 50.0),
            SensorReading(key: "Tp01", group: .cpu, celsius: 60.0),
            SensorReading(key: "Tg0f", group: .gpu, celsius: 45.0),
            SensorReading(key: "TB1T", group: .battery, celsius: 28.0),
            SensorReading(key: "TVM1", group: .other, celsius: 12.0)
        ]
    }

    // MARK: - CLI

    func testCLIPrintsLineReport() {
        var printed: [String] = []
        let code = HardwareSensorsCLI.handledExitCode(
            arguments: ["/App/BarTender", "--sensors"],
            readings: { self.sampleReadings() },
            printLine: { printed.append($0) },
            printError: { _ in }
        )
        XCTAssertEqual(code, 0)
        XCTAssertEqual(printed.first, "cpu=60.0\ngpu=45.0\nbattery=28.0")
    }

    func testCLIPrintsJSONReport() {
        var printed: [String] = []
        let code = HardwareSensorsCLI.handledExitCode(
            arguments: ["/App/BarTender", "--sensors-json"],
            readings: { self.sampleReadings() },
            printLine: { printed.append($0) },
            printError: { _ in }
        )
        XCTAssertEqual(code, 0)
        XCTAssertTrue(printed.first?.contains("\"unit\":\"celsius\"") == true)
    }

    func testCLIFailsWhenNoSensorsAvailable() {
        var errors: [String] = []
        let code = HardwareSensorsCLI.handledExitCode(
            arguments: ["/App/BarTender", "--sensors"],
            readings: { [] },
            printLine: { _ in },
            printError: { errors.append($0) }
        )
        XCTAssertEqual(code, 1)
        XCTAssertFalse(errors.isEmpty)
    }

}
