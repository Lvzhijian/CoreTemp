import Foundation

struct TemperatureHeadline: Equatable, Sendable {
    var celsius: Double
    var sourceName: String
    var sensorName: String
    var detail: String
}

struct ListedSensor: Equatable, Sendable, Identifiable {
    var id: String
    var sourceName: String
    var name: String
    var note: String?
    var celsius: Double

    var title: String {
        if let note, !note.isEmpty {
            return "\(name) · \(note)"
        }
        return name
    }
}

struct TemperatureReport: Equatable, Sendable {
    var headline: TemperatureHeadline?
    var sensors: [ListedSensor]
    var hidSummary: String
    var smcSummary: String
    var unclassified: [String]
    var unclassifiedExtra: Int

    static let empty = TemperatureReport(
        headline: nil,
        sensors: [],
        hidSummary: "",
        smcSummary: "",
        unclassified: [],
        unclassifiedExtra: 0
    )
}

/// Reads HID and SMC, then picks one real CPU sensor for the menu bar.
///
/// Nothing here synthesizes a temperature. If no CPU sensor qualifies,
/// `headline` stays nil and the menu shows `--°`.
enum TemperatureService {
    static func read() -> TemperatureReport {
        let hidList = SensorCopyHID()
        let smcList = SensorCopySMC()
        defer {
            var hidCopy = hidList
            var smcCopy = smcList
            SensorListFree(&hidCopy)
            SensorListFree(&smcCopy)
        }

        let hid = decode(hidList, source: .hid, detail: listDetail(hidList))
        let smc = decode(smcList, source: .smc, detail: listDetail(smcList))
        return makeReport(
            hid: hid.samples,
            smc: smc.samples,
            hidStatus: hid.status,
            hidDetail: hid.detail,
            smcStatus: smc.status,
            smcDetail: smc.detail
        )
    }
}

private enum TempSource {
    case hid
    case smc

    var label: String {
        switch self {
        case .hid: return "HID"
        case .smc: return "SMC"
        }
    }
}

private enum SensorRole {
    case performance
    case die
    case efficiency
    case soc
    case gpu
    case ignored
    case other

    var isCPU: Bool {
        switch self {
        case .performance, .die, .efficiency, .soc:
            return true
        case .gpu, .ignored, .other:
            return false
        }
    }
}

private struct RawSensor {
    var name: String
    var celsius: Double
    var source: TempSource
    var role: SensorRole
}

private func decode(_ list: SensorList, source: TempSource, detail: String) -> (samples: [RawSensor], status: Int32, detail: String) {
    let count = Int(list.count)
    guard count > 0, list.items != nil else {
        return ([], list.status, detail)
    }
    let base = list.items!
    var samples: [RawSensor] = []
    samples.reserveCapacity(count)
    for index in 0..<count {
        let item = base[index]
        let name = sensorName(item)
        guard isPlausible(item.celsius), !name.isEmpty else {
            continue
        }
        let role = source == .hid ? hidRole(name) : smcRole(name)
        samples.append(RawSensor(name: name, celsius: item.celsius, source: source, role: role))
    }
    return (samples, list.status, detail)
}

private func sensorName(_ item: SensorTemp) -> String {
    var copy = item
    return withUnsafePointer(to: &copy) { pointer in
        String(cString: SensorTempName(pointer))
    }
}

private func listDetail(_ list: SensorList) -> String {
    var copy = list
    return withUnsafePointer(to: &copy) { pointer in
        String(cString: SensorListDetail(pointer))
    }
}

private func isPlausible(_ celsius: Double) -> Bool {
    celsius.isFinite && celsius > 0 && celsius < 150
}

private func hidRole(_ name: String) -> SensorRole {
    let lower = name.lowercased()
    if lower.contains("tcal") || lower.contains("tdev") {
        return .ignored
    }
    if lower.contains("battery") || lower.contains("gas gauge") || lower.contains("nand")
        || lower.contains("airport") || lower.contains("wifi") || lower.contains("wlan")
        || lower.contains("palm") || lower.contains("skin") {
        return .ignored
    }
    if lower.contains("pacc") || lower.contains("performance") {
        return .performance
    }
    if lower.contains("eacc") || lower.contains("efficiency") {
        return .efficiency
    }
    if lower.contains("tdie") {
        return .die
    }
    if lower.contains("gpu") || (lower.hasPrefix("pmu tp") && lower.contains("g")) {
        return .gpu
    }
    if lower.contains("soc") {
        return .soc
    }
    if lower.contains("cpu") {
        return .die
    }
    return .other
}

private func smcRole(_ name: String) -> SensorRole {
    switch name {
    case "TCMz", "TCMb", "TC0D", "TC0E", "TC0F", "TC0P", "TC0H":
        return .die
    default:
        break
    }
    if name.hasPrefix("Tp") || name.hasPrefix("Tc") {
        return .performance
    }
    if name.hasPrefix("Te") {
        return .efficiency
    }
    if name.hasPrefix("Tg") || name.hasPrefix("TG") {
        return .gpu
    }
    if name.hasPrefix("TC") {
        return .die
    }
    if name.hasPrefix("TB") || name.hasPrefix("Ts") || name.hasPrefix("TW") || name.hasPrefix("Ta")
        || name.hasPrefix("Th") || name.hasPrefix("TL") || name.hasPrefix("TN") || name.hasPrefix("Tm") {
        return .ignored
    }
    return .other
}

private func makeReport(
    hid: [RawSensor],
    smc: [RawSensor],
    hidStatus: Int32,
    hidDetail: String,
    smcStatus: Int32,
    smcDetail: String
) -> TemperatureReport {
    let headlineSensor = pickHeadline(hid: hid, smc: smc)
    let headline = headlineSensor.map { sensor in
        TemperatureHeadline(
            celsius: sensor.celsius,
            sourceName: sensor.source.label,
            sensorName: sensor.name,
            detail: headlineDetail(sensor, hid: hid, smc: smc)
        )
    }
    let unclassified = unclassifiedLines(hid: hid, smc: smc)
    return TemperatureReport(
        headline: headline,
        sensors: listedSensors(hid: hid, smc: smc),
        hidSummary: sourceSummary(status: hidStatus, detail: hidDetail, samples: hid, empty: "没有枚举到 HID 温度服务", missingService: nil),
        smcSummary: sourceSummary(
            status: smcStatus,
            detail: smcDetail,
            samples: smc,
            empty: "已连接，但没有可用的温度键",
            missingService: "没有 AppleSMC 服务。较新的 Apple Silicon 系统常常如此，温度改看 HID。"
        ),
        unclassified: unclassified.lines,
        unclassifiedExtra: unclassified.extra
    )
}

private func pickHeadline(hid: [RawSensor], smc: [RawSensor]) -> RawSensor? {
    let hidCPU = hid.filter { $0.role.isCPU && isPlausible($0.celsius) }
    let smcCPU = smc.filter { $0.role.isCPU && isPlausible($0.celsius) }

    func smcKey(_ key: String) -> RawSensor? {
        smcCPU.first { $0.name == key }
    }

    if let sensor = smcKey("TCMz") ?? smcKey("TCMb") {
        return sensor
    }

    let hidDie = hidCPU.filter { $0.role == .performance || $0.role == .die }
    if let hottest = hidDie.max(by: { $0.celsius < $1.celsius }) {
        return hottest
    }

    for key in ["Tp0T", "Tp09", "Tp01", "Tp05", "Tp0D", "TC0P", "TC0E", "TC0D", "TC0F"] {
        if let sensor = smcKey(key) {
            return sensor
        }
    }

    if let hottest = hidCPU.filter({ $0.role == .efficiency }).max(by: { $0.celsius < $1.celsius }) {
        return hottest
    }
    if let hottest = hidCPU.filter({ $0.role == .soc }).max(by: { $0.celsius < $1.celsius }) {
        return hottest
    }
    return smcCPU.max(by: { $0.celsius < $1.celsius })
}

private func headlineDetail(_ headline: RawSensor, hid: [RawSensor], smc: [RawSensor]) -> String {
    switch headline.name {
    case "TCMz":
        if let average = smc.first(where: { $0.name == "TCMb" && isPlausible($0.celsius) }) {
            return String(format: "CPU 热点 · 平均 %.1f°", average.celsius)
        }
        return "CPU 热点"
    case "TCMb":
        return "CPU 平均"
    case "TC0P":
        return "CPU 邻近"
    case "TC0D", "TC0E", "TC0F":
        return "CPU 管芯"
    default:
        break
    }

    if headline.source == .hid {
        let group = hid.filter { $0.role == headline.role && isPlausible($0.celsius) }
        if group.count >= 2 {
            let average = group.reduce(0) { $0 + $1.celsius } / Double(group.count)
            return String(format: "同组平均 %.1f°", average)
        }
    }
    return "传感器读数"
}

private func listedSensors(hid: [RawSensor], smc: [RawSensor]) -> [ListedSensor] {
    let cpu = (hid + smc).filter { $0.role.isCPU && isPlausible($0.celsius) }
    let sorted = cpu.sorted { lhs, rhs in
        if lhs.celsius != rhs.celsius {
            return lhs.celsius > rhs.celsius
        }
        if lhs.source != rhs.source {
            return lhs.source == .hid
        }
        return lhs.name < rhs.name
    }

    var seen: [String: Int] = [:]
    var rows: [ListedSensor] = []
    for sensor in sorted {
        let base = "\(sensor.source.label):\(sensor.name)"
        let occurrence = seen[base, default: 0]
        seen[base] = occurrence + 1
        let id = occurrence == 0 ? base : "\(base)#\(occurrence + 1)"
        rows.append(
            ListedSensor(
                id: id,
                sourceName: sensor.source.label,
                name: sensor.name,
                note: smcGloss(sensor.name),
                celsius: sensor.celsius
            )
        )
    }

    let gpus = (hid + smc).filter { $0.role == .gpu && isPlausible($0.celsius) }
    if let hottest = gpus.max(by: { $0.celsius < $1.celsius }) {
        rows.append(
            ListedSensor(
                id: "gpu-max",
                sourceName: "GPU",
                name: hottest.name,
                note: gpus.count > 1 ? "\(gpus.count) 个里最热" : nil,
                celsius: hottest.celsius
            )
        )
    }
    return rows
}

private func smcGloss(_ name: String) -> String? {
    switch name {
    case "TCMz": return "CPU 热点"
    case "TCMb": return "CPU 平均"
    case "TC0P": return "CPU 邻近"
    case "TC0D", "TC0E", "TC0F": return "CPU 管芯"
    default: return nil
    }
}

private func unclassifiedLines(hid: [RawSensor], smc: [RawSensor]) -> (lines: [String], extra: Int) {
    let others = (hid + smc)
        .filter { $0.role == .other && isPlausible($0.celsius) }
        .sorted { $0.name < $1.name }
    let limit = 12
    let lines = others.prefix(limit).map { sensor in
        String(format: "%@  %@  %.1f°", sensor.source.label, sensor.name, sensor.celsius)
    }
    return (Array(lines), max(0, others.count - limit))
}

private func sourceSummary(
    status: Int32,
    detail: String,
    samples: [RawSensor],
    empty: String,
    missingService: String?
) -> String {
    switch status {
    case 0:
        if samples.isEmpty {
            return empty
        }
        let ignored = samples.filter { $0.role == .ignored }.count
        if ignored > 0 {
            return "读到 \(samples.count) 个，忽略了 \(ignored) 个非 CPU 读数"
        }
        return "读到 \(samples.count) 个"
    case 1:
        return "系统没有导出 HID 温度接口"
    case 2:
        return "无法创建 HID 客户端"
    case 3:
        return missingService ?? "没有找到服务"
    case 4:
        return "内存不足，没能保存传感器列表"
    default:
        if detail.hasPrefix("open:") {
            return "打不开 AppleSMC（\(detail)）。这不是密码提示；HID 仍会继续读。"
        }
        let code = detail.isEmpty ? String(format: "0x%08x", UInt32(bitPattern: status)) : detail
        return "读取失败（\(code)）"
    }
}
