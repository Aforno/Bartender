import Foundation
import XCTest
@testable import BarTender

final class HardwareSensorsTests: XCTestCase {
    // MARK: - FourCC

    func testFourCCRoundsTrip() {
        XCTAssertEqual(SMCConnection.fourCC("Tp09"), 0x54703039)
        XCTAssertEqual(SMCConnection.fourCCString(0x54703039), "Tp09")
        XCTAssertEqual(SMCConnection.fourCCString(SMCConnection.fourCC("TB1T")), "TB1T")
    }

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

    func testClassifiesAppleSiliconKeys() {
        XCTAssertEqual(SensorGroup.classify(smcKey: "Tp09"), .cpu)
        XCTAssertEqual(SensorGroup.classify(smcKey: "Tg0f"), .gpu)
        XCTAssertEqual(SensorGroup.classify(smcKey: "Te05"), .soc)
        XCTAssertEqual(SensorGroup.classify(smcKey: "Th0M"), .soc)
        XCTAssertEqual(SensorGroup.classify(smcKey: "TB1T"), .battery)
        XCTAssertEqual(SensorGroup.classify(smcKey: "TA0P"), .ambient)
        XCTAssertEqual(SensorGroup.classify(smcKey: "Tm0B"), .memory)
        XCTAssertEqual(SensorGroup.classify(smcKey: "Ts0P"), .storage)
    }

    func testClassifiesIntelKeys() {
        XCTAssertEqual(SensorGroup.classify(smcKey: "TC0D"), .cpu)
        XCTAssertEqual(SensorGroup.classify(smcKey: "TG0P"), .gpu)
        XCTAssertEqual(SensorGroup.classify(smcKey: "TN0D"), .soc)
    }

    func testLeavesUnknownFamiliesUnclassified() {
        XCTAssertEqual(SensorGroup.classify(smcKey: "TVM1"), .other)
        XCTAssertEqual(SensorGroup.classify(smcKey: "F0Ac"), .other)
        XCTAssertEqual(SensorGroup.classify(smcKey: "Tp"), .other)
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

    func testAggregatesPerGroup() {
        let stats = HardwareSensors.aggregate(readings: sampleReadings())
        XCTAssertEqual(stats[.cpu]?.average ?? 0, 55.0, accuracy: 0.001)
        XCTAssertEqual(stats[.cpu]?.maximum ?? 0, 60.0, accuracy: 0.001)
        XCTAssertEqual(stats[.gpu]?.maximum ?? 0, 45.0, accuracy: 0.001)
        XCTAssertNil(stats[.other])
        XCTAssertNil(stats[.storage])
    }

    func testLineReportUsesGroupMaximumAndSkipsMissingGroups() {
        let report = HardwareSensors.lineReport(readings: sampleReadings())
        let lines = report.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines, ["cpu=60.0", "gpu=45.0", "battery=28.0"])
    }

    func testJSONReportIncludesGroupsAndEverySensor() {
        let report = HardwareSensors.jsonReport(readings: sampleReadings())
        guard let data = report.data(using: .utf8),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            XCTFail("JSON report did not parse")
            return
        }
        XCTAssertEqual(parsed["unit"] as? String, "celsius")
        let groups = parsed["groups"] as? [String: Any]
        XCTAssertNotNil(groups?["cpu"])
        XCTAssertNil(groups?["other"])
        let sensors = parsed["sensors"] as? [[String: Any]]
        XCTAssertEqual(sensors?.count, 5)
        XCTAssertTrue(sensors?.contains { ($0["key"] as? String) == "TVM1" } == true)
    }

    // MARK: - CLI

    func testCLIIgnoresNormalAppInvocations() {
        XCTAssertNil(HardwareSensorsCLI.handledExitCode(arguments: ["/App/BarTender"]))
        XCTAssertNil(HardwareSensorsCLI.handledExitCode(arguments: ["/App/BarTender", "--debug"]))
    }

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

    // MARK: - Live hardware (skipped where sensors are unavailable, e.g. VMs)

    func testLiveReadingsArePlausibleWhenHardwareIsPresent() {
        let readings = HardwareSensorReader.temperatureReadings()
        guard !readings.isEmpty else { return }
        for reading in readings {
            XCTAssertTrue(
                HardwareSensors.plausibleRange.contains(reading.celsius),
                "Implausible reading \(reading.celsius)°C for \(reading.key)"
            )
        }
        XCTAssertTrue(readings.contains { $0.group != .other })
    }
}
