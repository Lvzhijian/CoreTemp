import Darwin
import Foundation

/// Aggregate interface throughput from `getifaddrs` / `if_data` (non-loopback).
final class NetworkSpeedReader {
    private struct Totals {
        var inbound: UInt64
        var outbound: UInt64
    }

    private var previous: Totals?
    private var previousTime: CFAbsoluteTime?

    func reset() {
        previous = nil
        previousTime = nil
    }

    func sample() -> NetworkReport {
        guard let totals = Self.readTotals() else {
            return NetworkReport(downloadBytesPerSecond: nil, uploadBytesPerSecond: nil, failed: true)
        }
        let now = CFAbsoluteTimeGetCurrent()
        defer {
            previous = totals
            previousTime = now
        }
        guard let previous, let previousTime else {
            return .waiting
        }
        let elapsed = now - previousTime
        guard elapsed > 0.2 else {
            return .waiting
        }
        let download = Double(totals.inbound &- previous.inbound) / elapsed
        let upload = Double(totals.outbound &- previous.outbound) / elapsed
        return NetworkReport(
            downloadBytesPerSecond: max(0, download),
            uploadBytesPerSecond: max(0, upload),
            failed: false
        )
    }

    private static func readTotals() -> Totals? {
        var cursor: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&cursor) == 0 else {
            return nil
        }
        defer { freeifaddrs(cursor) }

        var inbound: UInt64 = 0
        var outbound: UInt64 = 0
        var pointer = cursor
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            let flags = Int32(current.pointee.ifa_flags)
            guard (flags & IFF_UP) != 0, (flags & IFF_LOOPBACK) == 0 else {
                continue
            }
            guard let addr = current.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK) else {
                continue
            }
            guard let raw = current.pointee.ifa_data else {
                continue
            }
            let data = raw.assumingMemoryBound(to: if_data.self)
            inbound += UInt64(data.pointee.ifi_ibytes)
            outbound += UInt64(data.pointee.ifi_obytes)
        }
        return Totals(inbound: inbound, outbound: outbound)
    }
}

struct NetworkReport: Equatable, Sendable {
    var downloadBytesPerSecond: Double?
    var uploadBytesPerSecond: Double?
    var failed: Bool

    static let waiting = NetworkReport(
        downloadBytesPerSecond: nil,
        uploadBytesPerSecond: nil,
        failed: false
    )

    static func formatRate(_ bytesPerSecond: Double) -> String {
        formatRateFixed(bytesPerSecond)
    }

    /// Always 5 characters so the menu bar width stays stable.
    static func formatRateFixed(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        let raw: String
        if value < 1024 {
            raw = String(format: "%.0fB", value)
        } else if value < 1024 * 1024 {
            raw = String(format: "%.0fK", value / 1024)
        } else if value < 1024 * 1024 * 1024 {
            let mega = value / (1024 * 1024)
            raw = mega >= 10 ? String(format: "%.0fM", mega) : String(format: "%.1fM", mega)
        } else {
            let giga = value / (1024 * 1024 * 1024)
            raw = giga >= 10 ? String(format: "%.0fG", giga) : String(format: "%.1fG", giga)
        }
        if raw.count >= 5 {
            return String(raw.suffix(5))
        }
        return String(repeating: " ", count: 5 - raw.count) + raw
    }

    static func formatRateDetailed(_ bytesPerSecond: Double) -> String {
        let value = max(0, bytesPerSecond)
        if value < 1024 {
            return String(format: "%.0f B/s", value)
        }
        if value < 1024 * 1024 {
            return String(format: "%.1f KB/s", value / 1024)
        }
        if value < 1024 * 1024 * 1024 {
            return String(format: "%.2f MB/s", value / (1024 * 1024))
        }
        return String(format: "%.2f GB/s", value / (1024 * 1024 * 1024))
    }
}
