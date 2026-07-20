import Darwin
import Foundation

final class SystemMetricsCollector {
    private var previousCPUInfo: host_cpu_load_info?

    func cpuUsagePercent() -> Double {
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)
        var info = host_cpu_load_info()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        defer { previousCPUInfo = info }
        guard let previous = previousCPUInfo else { return 0 }

        return Self.cpuUsagePercent(
            previous: [
                previous.cpu_ticks.0,
                previous.cpu_ticks.1,
                previous.cpu_ticks.2,
                previous.cpu_ticks.3
            ],
            current: [
                info.cpu_ticks.0,
                info.cpu_ticks.1,
                info.cpu_ticks.2,
                info.cpu_ticks.3
            ]
        )
    }

    static func cpuUsagePercent(previous: [UInt32], current: [UInt32]) -> Double {
        guard previous.count == 4, current.count == 4 else { return 0 }
        let differences = zip(current, previous).map { currentTick, previousTick in
            Double(currentTick &- previousTick)
        }
        let total = differences.reduce(0, +)
        guard total > 0 else { return 0 }
        let busy = differences[0] + differences[1] + differences[3]
        return min(max((busy / total) * 100.0, 0), 100)
    }

    static func memoryUsage() -> (usedBytes: UInt64, totalBytes: UInt64, percent: Double) {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size)
        let result = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return (0, total, 0)
        }

        let pageSize = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count) * pageSize
        let inactive = UInt64(stats.inactive_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        let used = active + inactive + wired + compressed
        let percent = total > 0 ? (Double(used) / Double(total)) * 100.0 : 0
        return (used, total, min(percent, 100))
    }
}
