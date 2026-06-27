import Darwin
import Foundation
import IOKit

/// A point-in-time snapshot of system resource usage shown in the footer.
struct SystemStats: Equatable {
    /// Aggregate CPU busy percentage across all cores (0…100).
    var cpuPercent: Double = 0
    var memUsedBytes: UInt64 = 0
    var memTotalBytes: UInt64 = 0
    /// 1-minute load average.
    var loadAverage1m: Double = 0
    /// Network throughput (bytes/sec) since the previous sample.
    var netDownBytesPerSec: Double = 0
    var netUpBytesPerSec: Double = 0
    /// Disk throughput (bytes/sec) since the previous sample.
    var diskReadBytesPerSec: Double = 0
    var diskWriteBytesPerSec: Double = 0
    var diskUsedBytes: UInt64 = 0
    var diskTotalBytes: UInt64 = 0

    var memPercent: Double { memTotalBytes > 0 ? Double(memUsedBytes) / Double(memTotalBytes) * 100 : 0 }
    var diskPercent: Double { diskTotalBytes > 0 ? Double(diskUsedBytes) / Double(diskTotalBytes) * 100 : 0 }
    var netTotalBytesPerSec: Double { netDownBytesPerSec + netUpBytesPerSec }
    var diskIOBytesPerSec: Double { diskReadBytesPerSec + diskWriteBytesPerSec }

    static let zero = SystemStats()
}

/// One toggleable footer metric. Carries its display metadata so the footer and
/// the Settings list stay in sync.
enum SystemStatKind: String, CaseIterable, Identifiable, Codable {
    case cpu, memory, load, network, diskIO, diskSpace

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .cpu: "CPU"
        case .memory: "Memory"
        case .load: "Load average"
        case .network: "Network"
        case .diskIO: "Disk I/O"
        case .diskSpace: "Disk space"
        }
    }

    var systemImage: String {
        switch self {
        case .cpu: "cpu"
        case .memory: "memorychip"
        case .load: "gauge.with.dots.needle.33percent"
        case .network: "network"
        case .diskIO: "externaldrive.badge.timemachine"
        case .diskSpace: "internaldrive"
        }
    }

    /// Bounded 0–100 metrics scale their sparkline to a fixed 0…100; the rest
    /// auto-scale to the visible window's max.
    var isPercentage: Bool {
        switch self {
        case .cpu, .memory, .diskSpace: true
        case .load, .network, .diskIO: false
        }
    }

    /// Fixed width reserved for the value label so the footer layout doesn't
    /// shift as the digit count changes (e.g. "5%" → "100%", "0B/s" → "1.4M/s").
    var valueWidth: CGFloat {
        switch self {
        case .cpu, .memory, .diskSpace: 30 // "100%"
        case .load: 40 // up to "999.99"
        case .network, .diskIO: 58 // "1023.9K/s"
        }
    }

    /// The scalar plotted in the sparkline / history.
    func scalar(_ s: SystemStats) -> Double {
        switch self {
        case .cpu: s.cpuPercent
        case .memory: s.memPercent
        case .load: s.loadAverage1m
        case .network: s.netTotalBytesPerSec
        case .diskIO: s.diskIOBytesPerSec
        case .diskSpace: s.diskPercent
        }
    }

    /// Compact label shown in the footer.
    func compactLabel(_ s: SystemStats) -> String {
        switch self {
        case .cpu: "\(Int(s.cpuPercent.rounded()))%"
        case .memory: "\(Int(s.memPercent.rounded()))%"
        case .load: String(format: "%.2f", s.loadAverage1m)
        case .network: SystemStatsFormat.rate(s.netTotalBytesPerSec)
        case .diskIO: SystemStatsFormat.rate(s.diskIOBytesPerSec)
        case .diskSpace: "\(Int(s.diskPercent.rounded()))%"
        }
    }

    /// Verbose label shown in the hover popover.
    func detailLabel(_ s: SystemStats) -> String {
        switch self {
        case .cpu: "\(Int(s.cpuPercent.rounded()))% busy"
        case .memory: "\(SystemStatsFormat.bytes(s.memUsedBytes)) / \(SystemStatsFormat.bytes(s.memTotalBytes))"
        case .load: String(format: "%.2f (1-min)", s.loadAverage1m)
        case .network: "↓ \(SystemStatsFormat.rate(s.netDownBytesPerSec))   ↑ \(SystemStatsFormat.rate(s.netUpBytesPerSec))"
        case .diskIO: "R \(SystemStatsFormat.rate(s.diskReadBytesPerSec))   W \(SystemStatsFormat.rate(s.diskWriteBytesPerSec))"
        case .diskSpace: "\(SystemStatsFormat.bytes(s.diskUsedBytes)) / \(SystemStatsFormat.bytes(s.diskTotalBytes))"
        }
    }
}

/// Shared byte/rate formatting so the footer and popover agree.
enum SystemStatsFormat {
    static func bytes(_ value: UInt64) -> String {
        bytes(Double(value))
    }

    static func bytes(_ value: Double) -> String {
        let units = ["B", "K", "M", "G", "T"]
        var v = value
        var i = 0
        while v >= 1024, i < units.count - 1 {
            v /= 1024; i += 1
        }
        return i == 0 ? "\(Int(v))\(units[i])" : String(format: "%.1f%@", v, units[i])
    }

    static func rate(_ bytesPerSec: Double) -> String {
        "\(bytes(bytesPerSec))/s"
    }
}

/// Samples system-wide CPU / memory / load / network / disk via the Mach,
/// BSD, and IOKit host APIs.
///
/// Rate metrics (CPU, network, disk I/O) are deltas between successive
/// `sample()` calls, so the first sample reports 0 until a baseline exists.
/// This is a view-layer helper polled by the footer on a timer — it never
/// touches TCA state, so it can't thrash persistence or effects.
final class SystemStatsSampler {
    private var previousTicks: host_cpu_load_info?
    private var previousNet: (down: UInt64, up: UInt64)?
    private var previousDisk: (read: UInt64, write: UInt64)?
    private var previousTime: Date?

    func sample() -> SystemStats {
        let now = Date()
        let elapsed = previousTime.map { max(0.001, now.timeIntervalSince($0)) } ?? 0
        previousTime = now

        var stats = SystemStats()
        stats.cpuPercent = sampleCPU()
        stats.memUsedBytes = sampleMemoryUsed()
        stats.memTotalBytes = ProcessInfo.processInfo.physicalMemory
        stats.loadAverage1m = sampleLoad()

        let net = sampleNetwork()
        if let prev = previousNet, elapsed > 0 {
            stats.netDownBytesPerSec = Double(net.down &- prev.down) / elapsed
            stats.netUpBytesPerSec = Double(net.up &- prev.up) / elapsed
        }
        previousNet = net

        let disk = sampleDiskIO()
        if let prev = previousDisk, elapsed > 0 {
            stats.diskReadBytesPerSec = Double(disk.read &- prev.read) / elapsed
            stats.diskWriteBytesPerSec = Double(disk.write &- prev.write) / elapsed
        }
        previousDisk = disk

        let space = sampleDiskSpace()
        stats.diskUsedBytes = space.used
        stats.diskTotalBytes = space.total
        return stats
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

    /// Sum ifi_ibytes/ifi_obytes across non-loopback link-layer interfaces.
    /// The 32-bit counters wrap; wrapping subtraction keeps short-interval
    /// rates correct as long as < 4 GiB moved between samples.
    private func sampleNetwork() -> (down: UInt64, up: UInt64) {
        var down: UInt64 = 0
        var up: UInt64 = 0
        var addrs: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&addrs) == 0, let first = addrs else { return (0, 0) }
        defer { freeifaddrs(addrs) }
        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            let name = String(cString: cur.pointee.ifa_name)
            if cur.pointee.ifa_addr?.pointee.sa_family == UInt8(AF_LINK), !name.hasPrefix("lo"),
               let data = cur.pointee.ifa_data?.assumingMemoryBound(to: if_data.self) {
                down &+= UInt64(data.pointee.ifi_ibytes)
                up &+= UInt64(data.pointee.ifi_obytes)
            }
            ptr = cur.pointee.ifa_next
        }
        return (down, up)
    }

    /// Sum cumulative bytes read/written across every IOBlockStorageDriver.
    private func sampleDiskIO() -> (read: UInt64, write: UInt64) {
        var read: UInt64 = 0
        var write: UInt64 = 0
        var iterator: io_iterator_t = 0
        guard let matching = IOServiceMatching("IOBlockStorageDriver"),
              IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator) == KERN_SUCCESS
        else { return (0, 0) }
        defer { IOObjectRelease(iterator) }
        var drive = IOIteratorNext(iterator)
        while drive != 0 {
            var props: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(drive, &props, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let dict = props?.takeRetainedValue() as? [String: Any],
               let stats = dict["Statistics"] as? [String: Any] {
                read &+= (stats["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
                write &+= (stats["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            }
            IOObjectRelease(drive)
            drive = IOIteratorNext(iterator)
        }
        return (read, write)
    }

    private func sampleDiskSpace() -> (used: UInt64, total: UInt64) {
        let url = URL(fileURLWithPath: NSHomeDirectory())
        guard let values = try? url.resourceValues(forKeys: [.volumeTotalCapacityKey, .volumeAvailableCapacityKey]),
              let total = values.volumeTotalCapacity, let available = values.volumeAvailableCapacity
        else { return (0, 0) }
        let totalU = UInt64(max(0, total))
        let usedU = totalU - UInt64(max(0, available))
        return (usedU, totalU)
    }
}
