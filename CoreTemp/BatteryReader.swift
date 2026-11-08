import Foundation
import IOKit.ps

final class BatteryReader {
    func sample() -> BatteryReport {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              !list.isEmpty
        else {
            return BatteryReport.unavailable(failed: true)
        }

        for source in list {
            guard let raw = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any] else {
                continue
            }
            // Prefer an internal battery over pure AC descriptions.
            let type = raw[kIOPSTypeKey] as? String
            let isBattery = type == kIOPSInternalBatteryType || raw[kIOPSIsPresentKey] as? Bool == true
            if !isBattery, list.count > 1 {
                continue
            }
            return Self.report(from: raw)
        }

        if let first = list.first,
           let raw = IOPSGetPowerSourceDescription(blob, first)?.takeUnretainedValue() as? [String: Any] {
            return Self.report(from: raw)
        }
        return BatteryReport.unavailable(failed: true)
    }

    private static func report(from raw: [String: Any]) -> BatteryReport {
        let current = intValue(raw[kIOPSCurrentCapacityKey])
        let maxCapacity = intValue(raw[kIOPSMaxCapacityKey])
        let percent: Double?
        if let current, let maxCapacity, maxCapacity > 0 {
            percent = Swift.min(100, Swift.max(0, Double(current) / Double(maxCapacity) * 100))
        } else {
            percent = nil
        }

        let isCharging = raw[kIOPSIsChargingKey] as? Bool ?? false
        let isCharged = raw[kIOPSIsChargedKey] as? Bool ?? false
        let stateString = raw[kIOPSPowerSourceStateKey] as? String
        let onAC = stateString == kIOPSACPowerValue
        let present = raw[kIOPSIsPresentKey] as? Bool ?? (percent != nil)

        let mode: BatteryMode
        if !present {
            mode = .unavailable
        } else if isCharged || (onAC && !isCharging && (percent ?? 0) >= 99) {
            mode = .full
        } else if isCharging {
            mode = .charging
        } else if onAC {
            mode = .acPower
        } else {
            mode = .discharging
        }

        let timeToEmpty = minutesValue(raw[kIOPSTimeToEmptyKey])
        let timeToFull = minutesValue(raw[kIOPSTimeToFullChargeKey])
        let cycleCount = intValue(raw["Cycle Count"])
        let watts = powerWatts(from: raw)

        return BatteryReport(
            percent: percent,
            mode: mode,
            onAC: onAC,
            timeToEmptyMinutes: timeToEmpty,
            timeToFullMinutes: timeToFull,
            cycleCount: cycleCount,
            watts: watts,
            present: present,
            failed: false
        )
    }

    private static func intValue(_ any: Any?) -> Int? {
        if let n = any as? Int { return n }
        if let n = any as? NSNumber { return n.intValue }
        return nil
    }

    private static func minutesValue(_ any: Any?) -> Int? {
        guard let minutes = intValue(any), minutes > 0, minutes < 6000 else {
            // IOKit uses -1 / large sentinel when unknown.
            return nil
        }
        return minutes
    }

    private static func powerWatts(from raw: [String: Any]) -> Double? {
        // Prefer explicit wattage when present; else V(mV) * I(mA).
        if let watts = raw["Watts"] as? Double, watts != 0 {
            return abs(watts)
        }
        if let watts = (raw["Watts"] as? NSNumber)?.doubleValue, watts != 0 {
            return abs(watts)
        }
        let voltagemV = intValue(raw[kIOPSVoltageKey])
        let amperagemA = intValue(raw["Amperage"])
        guard let voltagemV, let amperagemA, voltagemV > 0, amperagemA != 0 else {
            return nil
        }
        return abs(Double(voltagemV) * Double(amperagemA) / 1_000_000)
    }
}

enum BatteryMode: String, Equatable, Sendable {
    case charging
    case discharging
    case full
    case acPower
    case unavailable
    case unknown

    var shortLabel: String {
        switch self {
        case .charging: return "充电"
        case .discharging: return "放电"
        case .full: return "满电"
        case .acPower: return "电源"
        case .unavailable: return "无电池"
        case .unknown: return "—"
        }
    }

    var detail: String {
        switch self {
        case .charging: return "正在充电"
        case .discharging: return "正在放电"
        case .full: return "已充满"
        case .acPower: return "接电源（未充）"
        case .unavailable: return "没有电池"
        case .unknown: return "状态未知"
        }
    }
}

struct BatteryReport: Equatable, Sendable {
    var percent: Double?
    var mode: BatteryMode
    var onAC: Bool
    var timeToEmptyMinutes: Int?
    var timeToFullMinutes: Int?
    var cycleCount: Int?
    var watts: Double?
    var present: Bool
    var failed: Bool

    static let waiting = BatteryReport(
        percent: nil,
        mode: .unknown,
        onAC: false,
        timeToEmptyMinutes: nil,
        timeToFullMinutes: nil,
        cycleCount: nil,
        watts: nil,
        present: true,
        failed: false
    )

    static func unavailable(failed: Bool) -> BatteryReport {
        BatteryReport(
            percent: nil,
            mode: .unavailable,
            onAC: false,
            timeToEmptyMinutes: nil,
            timeToFullMinutes: nil,
            cycleCount: nil,
            watts: nil,
            present: false,
            failed: failed
        )
    }

    var relevantMinutes: Int? {
        switch mode {
        case .charging:
            return timeToFullMinutes
        case .discharging:
            return timeToEmptyMinutes
        default:
            return nil
        }
    }

    static func formatMinutes(_ minutes: Int) -> String {
        let h = minutes / 60
        let m = minutes % 60
        if h > 0 {
            return String(format: "%d:%02d", h, m)
        }
        return String(format: "%d 分钟", m)
    }
}
