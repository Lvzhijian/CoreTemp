import Foundation
import IOKit

final class GPUActivityReader {
    func sample() -> GPUReport {
        let gpus = Self.enumerateGPUs()
        guard !gpus.isEmpty else {
            return GPUReport(
                active: .unknown,
                integratedName: nil,
                discreteName: nil,
                integratedUtilization: nil,
                discreteUtilization: nil,
                detail: "没有读到 GPU",
                failed: true
            )
        }

        let integrated = gpus.filter(\.isIntegrated)
        let discrete = gpus.filter { !$0.isIntegrated }

        let integratedUtil = integrated.map(\.utilization).compactMap { $0 }.max()
        let discreteUtil = discrete.map(\.utilization).compactMap { $0 }.max()
        let integratedName = integrated.first?.name
        let discreteName = discrete.first?.name

        let active: GPUKind
        let detail: String
        if discrete.isEmpty {
            active = .integrated
            let utilText = integratedUtil.map { String(format: "%.0f%%", $0) } ?? "—"
            detail = "只有集显（\(integratedName ?? "GPU") · \(utilText)）"
        } else if integrated.isEmpty {
            active = .discrete
            let utilText = discreteUtil.map { String(format: "%.0f%%", $0) } ?? "—"
            detail = "只有独显（\(discreteName ?? "GPU") · \(utilText)）"
        } else {
            // Dual-GPU Mac: treat discrete as "working" when it reports meaningful load
            // or when Apple has it powered with non-trivial utilization.
            let discreteWorking = (discreteUtil ?? 0) >= 1.5
            active = discreteWorking ? .discrete : .integrated
            let iText = integratedUtil.map { String(format: "%.0f%%", $0) } ?? "—"
            let dText = discreteUtil.map { String(format: "%.0f%%", $0) } ?? "—"
            if discreteWorking {
                detail = "独显工作中 · \(discreteName ?? "独显") \(dText)（集显 \(iText)）"
            } else {
                detail = "集显工作中 · \(integratedName ?? "集显") \(iText)（独显待命 \(dText)）"
            }
        }

        return GPUReport(
            active: active,
            integratedName: integratedName,
            discreteName: discreteName,
            integratedUtilization: integratedUtil,
            discreteUtilization: discreteUtil,
            detail: detail,
            failed: false
        )
    }

    private struct GPUInfo {
        var name: String
        var isIntegrated: Bool
        var utilization: Double?
    }

    private static func enumerateGPUs() -> [GPUInfo] {
        var results: [GPUInfo] = []
        var iterator: io_iterator_t = 0
        let matching = IOServiceMatching("IOAccelerator")
        let kr = IOServiceGetMatchingServices(kIOMainPortDefault, matching, &iterator)
        guard kr == KERN_SUCCESS else {
            return results
        }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iterator)
            }
            guard let props = copyProperties(service) else { continue }
            let bundle = (props["CFBundleIdentifier"] as? String) ?? ""
            let model = (props["model"] as? String)
                ?? (props["IODTModel"] as? String)
                ?? (props["IOClass"] as? String)
                ?? bundle
            let name = prettyName(model: model, bundle: bundle)
            let integrated = isIntegrated(name: name, bundle: bundle)
            let util = utilization(from: props)
            // Skip duplicate / helper nodes without useful identity
            if name.isEmpty { continue }
            if results.contains(where: { $0.name == name && $0.isIntegrated == integrated }) {
                // Keep the higher utilization reading
                if let idx = results.firstIndex(where: { $0.name == name && $0.isIntegrated == integrated }) {
                    let existing = results[idx].utilization ?? -1
                    let next = util ?? -1
                    if next > existing {
                        results[idx].utilization = util
                    }
                }
                continue
            }
            results.append(GPUInfo(name: name, isIntegrated: integrated, utilization: util))
        }
        return results
    }

    private static func copyProperties(_ service: io_object_t) -> [String: Any]? {
        var ref: Unmanaged<CFMutableDictionary>?
        let kr = IORegistryEntryCreateCFProperties(service, &ref, kCFAllocatorDefault, 0)
        guard kr == KERN_SUCCESS, let dict = ref?.takeRetainedValue() as? [String: Any] else {
            return nil
        }
        return dict
    }

    private static func utilization(from props: [String: Any]) -> Double? {
        let stats = (props["PerformanceStatistics"] as? [String: Any])
            ?? (props["PerformanceStatisticsAccum"] as? [String: Any])
        guard let stats else { return nil }
        let keys = [
            "Device Utilization %",
            "GPU Activity(%)",
            "Device Utilization % at cur p-state",
            "Renderer Utilization %"
        ]
        var values: [Double] = []
        for key in keys {
            if let number = stats[key] as? NSNumber {
                values.append(number.doubleValue)
            }
        }
        // Some Intel nodes expose unit utilizations only
        for (key, value) in stats {
            if key.contains("Utilization"), let number = value as? NSNumber {
                values.append(number.doubleValue)
            }
        }
        return values.max()
    }

    private static func isIntegrated(name: String, bundle: String) -> Bool {
        let hay = (name + " " + bundle).lowercased()
        if hay.contains("amd") || hay.contains("radeon") || hay.contains("nvidia") || hay.contains("geforce") {
            return false
        }
        if hay.contains("intel") || hay.contains("iris") || hay.contains("uhd") || hay.contains("hd graphics") {
            return true
        }
        if hay.contains("apple") {
            return true
        }
        // Built-in Intel kexts
        if bundle.contains("AppleIntel") { return true }
        if bundle.contains("AMDRadeon") || bundle.contains("NVDA") { return false }
        return true
    }

    private static func prettyName(model: String, bundle: String) -> String {
        let trimmed = model.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty, trimmed != "IOAccelerator" {
            return trimmed
        }
        if bundle.contains("AMDRadeon") { return "AMD Radeon" }
        if bundle.contains("AppleIntel") { return "Intel Graphics" }
        if bundle.contains("Apple") { return "Apple GPU" }
        return trimmed
    }
}

enum GPUKind: String, Equatable, Sendable {
    case integrated
    case discrete
    case unknown

    var shortLabel: String {
        switch self {
        case .integrated: return "集显"
        case .discrete: return "独显"
        case .unknown: return "显卡"
        }
    }
}

struct GPUReport: Equatable, Sendable {
    var active: GPUKind
    var integratedName: String?
    var discreteName: String?
    var integratedUtilization: Double?
    var discreteUtilization: Double?
    var detail: String
    var failed: Bool

    static let waiting = GPUReport(
        active: .unknown,
        integratedName: nil,
        discreteName: nil,
        integratedUtilization: nil,
        discreteUtilization: nil,
        detail: "正在识别显卡",
        failed: false
    )
}
