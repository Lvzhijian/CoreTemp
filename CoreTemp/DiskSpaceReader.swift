import Foundation

final class DiskSpaceReader {
    func sample() -> DiskReport {
        let url = URL(fileURLWithPath: "/")
        do {
            let values = try url.resourceValues(forKeys: [
                .volumeTotalCapacityKey,
                .volumeAvailableCapacityForImportantUsageKey,
                .volumeAvailableCapacityKey,
                .volumeNameKey
            ])
            let total = values.volumeTotalCapacity.map(UInt64.init)
            let freeImportant = values.volumeAvailableCapacityForImportantUsage.map(UInt64.init)
            let free = freeImportant
                ?? values.volumeAvailableCapacity.map(UInt64.init)
            guard let total, let free else {
                return DiskReport(
                    totalBytes: nil,
                    freeBytes: nil,
                    volumeName: values.volumeName,
                    failed: true
                )
            }
            return DiskReport(
                totalBytes: total,
                freeBytes: free,
                volumeName: values.volumeName ?? "Macintosh HD",
                failed: false
            )
        } catch {
            return DiskReport(totalBytes: nil, freeBytes: nil, volumeName: nil, failed: true)
        }
    }
}

struct DiskReport: Equatable, Sendable {
    var totalBytes: UInt64?
    var freeBytes: UInt64?
    var volumeName: String?
    var failed: Bool

    static let waiting = DiskReport(
        totalBytes: nil,
        freeBytes: nil,
        volumeName: nil,
        failed: false
    )

    var usedBytes: UInt64? {
        guard let totalBytes, let freeBytes, totalBytes >= freeBytes else { return nil }
        return totalBytes - freeBytes
    }

    var usedPercent: Double? {
        guard let totalBytes, totalBytes > 0, let usedBytes else { return nil }
        return Double(usedBytes) / Double(totalBytes) * 100
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / (1000 * 1000 * 1000) // decimal GB like Finder
        if gb >= 1000 {
            return String(format: "%.2f TB", gb / 1000)
        }
        if gb >= 100 {
            return String(format: "%.0f GB", gb)
        }
        return String(format: "%.1f GB", gb)
    }
}
