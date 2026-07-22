import Foundation
import IOKit

/// A single hardware temperature reading in degrees Celsius.
struct SensorReading: Equatable, Sendable {
    /// SMC key, e.g. "Tp09".
    var key: String
    var group: SensorGroup
    var celsius: Double
}

/// Component families temperature sensors are grouped into. The raw value is the
/// stable machine-facing name used by `--sensors` output.
enum SensorGroup: String, CaseIterable, Codable, Sendable {
    case cpu
    case gpu
    case soc
    case battery
    case ambient
    case memory
    case storage
    case other

    var displayName: String {
        switch self {
        case .cpu: return "CPU"
        case .gpu: return "GPU"
        case .soc: return "SoC"
        case .battery: return "Battery"
        case .ambient: return "Ambient"
        case .memory: return "Memory"
        case .storage: return "Storage"
        case .other: return "Other"
        }
    }

    /// Best-effort mapping from an SMC key to a component family. Apple Silicon uses
    /// lowercase second letters (Tp = CPU cluster, Tg = GPU, Te/Th = SoC clusters,
    /// Ts = NAND/storage), Intel uses uppercase (TC = CPU, TG = GPU, TB = battery,
    /// TA = ambient, TM = memory, TN = northbridge/PCH). Families whose readings are
    /// known to be unreliable or non-thermal (voltage rails, power domains) stay `other`.
    static func classify(smcKey key: String) -> SensorGroup {
        // Charger proximity on Apple Silicon, not a compute component.
        if key == "TCHP" { return .other }
        guard key.count == 4, key.hasPrefix("T") else { return .other }
        let second = key[key.index(key.startIndex, offsetBy: 1)]
        switch second {
        case "p", "P", "C": return .cpu
        case "g", "G": return .gpu
        case "e", "h", "N": return .soc
        case "B": return .battery
        case "A", "a": return .ambient
        case "m", "M": return .memory
        case "s": return .storage
        default: return .other
        }
    }
}

/// Pure decoding, aggregation, and report formatting for sensor readings.
enum HardwareSensors {
    /// Accepted range for a plausible component temperature in °C. Unpopulated SMC
    /// sensors report 0 °C or single-digit values, and running components stay
    /// above 10 °C and below 150 °C, so outliers are treated as absent.
    static let plausibleRange: ClosedRange<Double> = 10...150

    /// Decodes an SMC value payload. `flt ` is a little-endian Float32 (the SMC
    /// coprocessor is little-endian ARM); `spXY` is a big-endian signed fixed-point
    /// Int16 with X integer and Y fraction bits (hex digits), e.g. sp78 = value/256.
    static func decodeValue(type: String, bytes: [UInt8]) -> Double? {
        switch type {
        case "flt ":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0])
                | UInt32(bytes[1]) << 8
                | UInt32(bytes[2]) << 16
                | UInt32(bytes[3]) << 24
            return Double(Float(bitPattern: bits))
        default:
            guard type.hasPrefix("sp"), type.count == 4,
                  let fractionBits = Int(String(type.last!), radix: 16),
                  bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: UInt16(bytes[0]) << 8 | UInt16(bytes[1]))
            return Double(raw) / Double(1 << fractionBits)
        }
    }

    struct GroupStats: Equatable, Sendable {
        var average: Double
        var maximum: Double
    }

    /// Aggregates readings per group. `other` sensors are reported individually but
    /// never contribute to component aggregates.
    static func aggregate(readings: [SensorReading]) -> [SensorGroup: GroupStats] {
        var result: [SensorGroup: GroupStats] = [:]
        for group in SensorGroup.allCases where group != .other {
            let values = readings.filter { $0.group == group }.map(\.celsius)
            guard !values.isEmpty else { continue }
            let average = values.reduce(0, +) / Double(values.count)
            let maximum = values.max() ?? average
            result[group] = GroupStats(average: average, maximum: maximum)
        }
        return result
    }

    static func format(_ value: Double) -> String {
        String(format: "%.1f", value)
    }

    /// Machine-parseable `key=value` lines, one per available component group.
    /// Each value is the hottest sensor of the group in °C.
    static func lineReport(readings: [SensorReading]) -> String {
        let stats = aggregate(readings: readings)
        return SensorGroup.allCases.compactMap { group in
            guard let value = stats[group] else { return nil }
            return "\(group.rawValue)=\(format(value.maximum))"
        }.joined(separator: "\n")
    }

    /// Detailed JSON report with per-group aggregates and every individual sensor.
    static func jsonReport(readings: [SensorReading]) -> String {
        let stats = aggregate(readings: readings)
        let groups = SensorGroup.allCases.compactMap { group -> String? in
            guard let value = stats[group] else { return nil }
            return """
            "\(group.rawValue)":{"average":\(format(value.average)),"maximum":\(format(value.maximum))}
            """
        }.joined(separator: ",")
        let sensors = readings
            .sorted { $0.key < $1.key }
            .map { reading in
                """
                {"key":"\(reading.key)","group":"\(reading.group.rawValue)","celsius":\(format(reading.celsius))}
                """
            }
            .joined(separator: ",")
        return "{\"unit\":\"celsius\",\"groups\":{\(groups)},\"sensors\":[\(sensors)]}"
    }
}

/// Reads live temperature sensors from the SMC (CPU/GPU/SoC/battery/storage/…).
enum HardwareSensorReader {
    static func temperatureReadings() -> [SensorReading] {
        smcTemperatureReadings()
    }

    static func smcTemperatureReadings() -> [SensorReading] {
        let smc = SMCConnection()
        guard smc.open() else { return [] }
        defer { smc.close() }
        guard let count = smc.keyCount(), count > 0 else { return [] }

        var readings: [SensorReading] = []
        readings.reserveCapacity(64)
        for index in 0..<count {
            guard let key = smc.key(at: index), key.hasPrefix("T"),
                  let (type, bytes) = smc.readRaw(key),
                  let value = HardwareSensors.decodeValue(type: type, bytes: bytes),
                  HardwareSensors.plausibleRange.contains(value) else { continue }
            readings.append(SensorReading(
                key: key,
                group: SensorGroup.classify(smcKey: key),
                celsius: value
            ))
        }
        return readings
    }
}

/// Handles the app's sensor command-line interface used by generated tools.
/// Invoked as `"$BARTENDER_CLI" --sensors` or `"$BARTENDER_CLI" --sensors-json`.
enum HardwareSensorsCLI {
    static let sensorsFlag = "--sensors"
    static let sensorsJSONFlag = "--sensors-json"

    /// When `arguments` request a sensor report, prints the report and returns the
    /// exit code the process should terminate with. Returns nil for normal app runs.
    static func handledExitCode(
        arguments: [String] = CommandLine.arguments,
        readings: () -> [SensorReading] = { HardwareSensorReader.temperatureReadings() },
        printLine: (String) -> Void = { Swift.print($0) },
        printError: (String) -> Void = {
            FileHandle.standardError.write(Data(($0 + "\n").utf8))
        }
    ) -> Int? {
        let wantsJSON = arguments.contains(sensorsJSONFlag)
        let wantsLines = arguments.contains(sensorsFlag)
        guard wantsJSON || wantsLines else { return nil }

        let values = readings()
        guard !values.isEmpty else {
            printError("No temperature sensors are available on this Mac.")
            return 1
        }
        printLine(wantsJSON
            ? HardwareSensors.jsonReport(readings: values)
            : HardwareSensors.lineReport(readings: values))
        return 0
    }
}

// MARK: - SMC user client

/// Wire layout of `SMCKeyData_t` (exactly 80 bytes). The explicit padding after
/// `keyInfo` reproduces the C struct's tail padding so Swift's layout matches.
private struct SMCVersion {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyInfoData {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
}

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCVersion()
    var pLimitData = SMCPLimitData()
    var keyInfo = SMCKeyInfoData()
    var padding: UInt16 = 0
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0,
         0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0, 0)
}

final class SMCConnection {
    private enum Selector {
        static let handleYPCEvent: UInt32 = 2
        static let readKey: UInt8 = 5
        static let getKeyCount: UInt8 = 7
        static let getKeyFromIndex: UInt8 = 8
        static let getKeyInfo: UInt8 = 9
    }

    private var connection: io_connect_t = 0

    /// True when the SMCKeyData wire layout matches the 80 bytes the driver expects.
    private static var hasValidLayout: Bool {
        MemoryLayout<SMCKeyData>.size == 80
    }

    func open() -> Bool {
        guard Self.hasValidLayout else { return false }
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        defer { IOObjectRelease(service) }
        return IOServiceOpen(service, mach_task_self_, 0, &connection) == KERN_SUCCESS
    }

    func close() {
        if connection != 0 {
            IOServiceClose(connection)
            connection = 0
        }
    }

    @discardableResult
    private func call(_ input: inout SMCKeyData) -> (kern: kern_return_t, data: SMCKeyData) {
        var output = SMCKeyData()
        var outputSize = MemoryLayout<SMCKeyData>.size
        let kern = IOConnectCallStructMethod(
            connection,
            Selector.handleYPCEvent,
            &input,
            MemoryLayout<SMCKeyData>.size,
            &output,
            &outputSize
        )
        return (kern, output)
    }

    func keyCount() -> UInt32? {
        var data = SMCKeyData()
        data.data8 = Selector.getKeyCount
        let (kern, output) = call(&data)
        guard kern == KERN_SUCCESS, output.result == 0 else { return nil }
        if output.keyInfo.dataSize > 0, output.keyInfo.dataSize < 100_000 {
            return output.keyInfo.dataSize
        }
        // Apple Silicon returns the count big-endian in data32.
        let swapped = output.data32.byteSwapped
        if swapped > 0, swapped < 100_000 { return swapped }
        if output.data32 > 0, output.data32 < 100_000 { return output.data32 }
        return nil
    }

    func key(at index: UInt32) -> String? {
        var data = SMCKeyData()
        data.data8 = Selector.getKeyFromIndex
        data.data32 = index
        let (kern, output) = call(&data)
        guard kern == KERN_SUCCESS, output.result == 0 else { return nil }
        return Self.fourCCString(output.key)
    }

    func readRaw(_ key: String) -> (type: String, bytes: [UInt8])? {
        var info = SMCKeyData()
        info.key = Self.fourCC(key)
        info.data8 = Selector.getKeyInfo
        let (infoKern, infoOutput) = call(&info)
        guard infoKern == KERN_SUCCESS, infoOutput.result == 0 else { return nil }

        var data = SMCKeyData()
        data.key = Self.fourCC(key)
        data.keyInfo.dataSize = infoOutput.keyInfo.dataSize
        data.data8 = Selector.readKey
        let (kern, output) = call(&data)
        guard kern == KERN_SUCCESS, output.result == 0 else { return nil }

        var bytes: [UInt8] = []
        withUnsafeBytes(of: output.bytes) { buffer in
            bytes = Array(buffer.prefix(Int(infoOutput.keyInfo.dataSize)))
        }
        return (Self.fourCCString(infoOutput.keyInfo.dataType), bytes)
    }

    static func fourCC(_ string: String) -> UInt32 {
        var result: UInt32 = 0
        for byte in string.utf8.prefix(4) {
            result = (result << 8) | UInt32(byte)
        }
        return result
    }

    static func fourCCString(_ code: UInt32) -> String {
        let bytes = [
            UInt8((code >> 24) & 0xFF),
            UInt8((code >> 16) & 0xFF),
            UInt8((code >> 8) & 0xFF),
            UInt8(code & 0xFF)
        ]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }
}
