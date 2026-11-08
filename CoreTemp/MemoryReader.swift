import Darwin
import Foundation

final class MemoryReader {
    func sample() -> MemoryReport {
        let total = ProcessInfo.processInfo.physicalMemory
        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(
            MemoryLayout<vm_statistics64_data_t>.size / MemoryLayout<integer_t>.size
        )
        let kr = withUnsafeMutablePointer(to: &stats) { pointer in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics64(mach_host_self(), HOST_VM_INFO64, rebound, &count)
            }
        }
        guard kr == KERN_SUCCESS else {
            return MemoryReport(
                usedBytes: nil,
                totalBytes: total,
                appBytes: nil,
                wiredBytes: nil,
                compressedBytes: nil,
                pressure: .unknown,
                failed: true
            )
        }

        let page = UInt64(vm_kernel_page_size)
        let active = UInt64(stats.active_count) * page
        let inactive = UInt64(stats.inactive_count) * page
        let wired = UInt64(stats.wire_count) * page
        let compressed = UInt64(stats.compressor_page_count) * page
        let speculative = UInt64(stats.speculative_count) * page
        let free = UInt64(stats.free_count) * page

        // Activity Monitor-style "Memory Used": active + wired + compressed
        let used = active + wired + compressed
        let app = active + inactive + speculative
        let pressure = Self.pressure(stats: stats, free: free, total: total)

        return MemoryReport(
            usedBytes: used,
            totalBytes: total,
            appBytes: app,
            wiredBytes: wired,
            compressedBytes: compressed,
            pressure: pressure,
            failed: false
        )
    }

    private static func pressure(stats: vm_statistics64, free: UInt64, total: UInt64) -> MemoryPressure {
        // Prefer compressor/swap signal when free is scarce.
        let freeRatio = Double(free) / Double(max(total, 1))
        let compressor = Double(stats.compressor_page_count)
        let totalPages = Double(total / UInt64(vm_kernel_page_size))
        let compressRatio = compressor / max(totalPages, 1)
        if freeRatio < 0.05 || compressRatio > 0.25 {
            return .serious
        }
        if freeRatio < 0.12 || compressRatio > 0.12 {
            return .warning
        }
        return .normal
    }
}

enum MemoryPressure: String, Equatable, Sendable {
    case normal
    case warning
    case serious
    case unknown
}

struct MemoryReport: Equatable, Sendable {
    var usedBytes: UInt64?
    var totalBytes: UInt64
    var appBytes: UInt64?
    var wiredBytes: UInt64?
    var compressedBytes: UInt64?
    var pressure: MemoryPressure
    var failed: Bool

    static let waiting = MemoryReport(
        usedBytes: nil,
        totalBytes: ProcessInfo.processInfo.physicalMemory,
        appBytes: nil,
        wiredBytes: nil,
        compressedBytes: nil,
        pressure: .unknown,
        failed: false
    )

    var usagePercent: Double? {
        guard let usedBytes, totalBytes > 0 else { return nil }
        return Double(usedBytes) / Double(totalBytes) * 100
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let value = Double(bytes)
        if value < 1024 * 1024 * 1024 {
            return String(format: "%.1f GB", value / (1024 * 1024 * 1024))
        }
        return String(format: "%.1f GB", value / (1024 * 1024 * 1024))
    }
}
