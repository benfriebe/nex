import Darwin
import Foundation

/// A point-in-time snapshot of system resource usage shown in the footer.
struct SystemStats: Equatable {
    /// Aggregate CPU busy percentage across all cores (0…100).
    var cpuPercent: Double
    var memUsedBytes: UInt64
    var memTotalBytes: UInt64
    /// 1-minute load average.
    var loadAverage1m: Double

    var memPercent: Double {
        memTotalBytes > 0 ? Double(memUsedBytes) / Double(memTotalBytes) * 100 : 0
    }

    static let zero = SystemStats(cpuPercent: 0, memUsedBytes: 0, memTotalBytes: 0, loadAverage1m: 0)
}

/// Samples system-wide CPU / memory / load via the Mach host APIs.
///
/// CPU is a delta of host CPU ticks between successive `sample()` calls, so the
/// very first sample reports 0 until a baseline exists. This is a view-layer
/// helper polled by the footer on a timer — it never touches TCA state, so it
/// can't thrash persistence or effects.
final class SystemStatsSampler {
    private var previousTicks: host_cpu_load_info?

    func sample() -> SystemStats {
        SystemStats(
            cpuPercent: sampleCPU(),
            memUsedBytes: sampleMemoryUsed(),
            memTotalBytes: ProcessInfo.processInfo.physicalMemory,
            loadAverage1m: sampleLoad()
        )
    }

    private func sampleCPU() -> Double {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &info) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        defer { previousTicks = info }
        guard let prev = previousTicks else { return 0 }
        // cpu_ticks is (user, system, idle, nice). Wrapping subtraction guards
        // the (rare) counter rollover.
        let user = Double(info.cpu_ticks.0 &- prev.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- prev.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- prev.cpu_ticks.3)
        let busy = user + system + nice
        let total = busy + idle
        guard total > 0 else { return 0 }
        return min(100, max(0, busy / total * 100))
    }

    private func sampleMemoryUsed() -> UInt64 {
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64_data_t>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) { ptr in
            ptr.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }
        let pageSize = UInt64(sysconf(_SC_PAGESIZE))
        // Approximates Activity Monitor's "Memory Used" (App + Wired +
        // Compressed); inactive/free are treated as available.
        let active = UInt64(stats.active_count)
        let wired = UInt64(stats.wire_count)
        let compressed = UInt64(stats.compressor_page_count)
        return (active + wired + compressed) * pageSize
    }

    private func sampleLoad() -> Double {
        var loads = [Double](repeating: 0, count: 3)
        guard getloadavg(&loads, 3) == 3 else { return 0 }
        return loads[0]
    }
}
