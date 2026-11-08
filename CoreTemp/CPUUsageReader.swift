import Darwin

/// System-wide and per-logical-CPU utilization from Mach tick counters.
///
/// The percentage is the change between two samples, so the first call only
/// stores a baseline and reports no usage. Call `reset()` after sleep so the
/// next window does not span the time the machine was suspended.
///
/// Not thread-safe. The sensor queue is the only caller.
final class CPUUsageReader {
    private struct Ticks {
        var user: UInt64
        var system: UInt64
        var idle: UInt64
        var nice: UInt64

        static let zero = Ticks(user: 0, system: 0, idle: 0, nice: 0)

        static func + (lhs: Ticks, rhs: Ticks) -> Ticks {
            Ticks(
                user: lhs.user + rhs.user,
                system: lhs.system + rhs.system,
                idle: lhs.idle + rhs.idle,
                nice: lhs.nice + rhs.nice
            )
        }
    }

    private struct TickSnapshot {
        var system: Ticks
        var cores: [Ticks]
    }

    private var previous: TickSnapshot?
    private var cachedTitle: String?
    private var cachedPerformanceCount: Int?
    private var cachedEfficiencyCount: Int?
    private var didReadTopology = false

    func reset() {
        previous = nil
    }

    func sample() -> CPUReport {
        let title = hardwareTitle()
        let topology = readTopology()
        guard let current = Self.readSnapshot() else {
            return CPUReport(
                usage: nil,
                user: nil,
                system: nil,
                idle: nil,
                cores: [],
                performanceCount: topology.performance,
                efficiencyCount: topology.efficiency,
                title: title,
                failed: true
            )
        }

        guard let previous, previous.cores.count == current.cores.count else {
            self.previous = current
            return CPUReport(
                usage: nil,
                user: nil,
                system: nil,
                idle: nil,
                cores: [],
                performanceCount: topology.performance,
                efficiencyCount: topology.efficiency,
                title: title,
                failed: false
            )
        }

        self.previous = current
        let overall = Self.percents(from: previous.system, to: current.system)
        let cores = zip(previous.cores, current.cores).map { earlier, later in
            Self.percents(from: earlier, to: later)?.total ?? 0
        }
        return CPUReport(
            usage: overall?.total,
            user: overall?.user,
            system: overall?.system,
            idle: overall?.idle,
            cores: overall == nil ? [] : cores,
            performanceCount: topology.performance,
            efficiencyCount: topology.efficiency,
            title: title,
            failed: overall == nil
        )
    }

    private func hardwareTitle() -> String {
        if let cachedTitle {
            return cachedTitle
        }
        let brand = Self.sysctlString("machdep.cpu.brand_string") ?? ""
        let model = Self.sysctlString("hw.model") ?? ""
        let title = Self.shortTitle(brand: brand, model: model)
        cachedTitle = title
        return title
    }

    private func readTopology() -> (performance: Int?, efficiency: Int?) {
        if didReadTopology {
            return (cachedPerformanceCount, cachedEfficiencyCount)
        }
        didReadTopology = true
        cachedPerformanceCount = Self.sysctlInt("hw.perflevel0.logicalcpu")
        cachedEfficiencyCount = Self.sysctlInt("hw.perflevel1.logicalcpu")
        return (cachedPerformanceCount, cachedEfficiencyCount)
    }

    private static func shortTitle(brand: String, model: String) -> String {
        let trimmed = brand.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return model.isEmpty ? "这台 Mac" : model
        }
        if trimmed.hasPrefix("Apple") {
            return trimmed
        }
        var text = trimmed
            .replacingOccurrences(of: "(R)", with: "")
            .replacingOccurrences(of: "(TM)", with: "")
            .replacingOccurrences(of: " CPU", with: "")
        if let range = text.range(of: " @") {
            text = String(text[..<range.lowerBound])
        }
        while text.contains("  ") {
            text = text.replacingOccurrences(of: "  ", with: " ")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if text.count > 32 {
            text = String(text.prefix(32)).trimmingCharacters(in: .whitespaces)
        }
        return text.isEmpty ? (model.isEmpty ? "这台 Mac" : model) : text
    }

    /// Prefer the sum of logical CPUs so the menu percentage and the core
    /// grid describe the same window. Fall back to the host aggregate.
    private static func readSnapshot() -> TickSnapshot? {
        if let cores = readCoreTicks(), !cores.isEmpty {
            let system = cores.reduce(.zero, +)
            return TickSnapshot(system: system, cores: cores)
        }
        if let system = readSystemTicks() {
            return TickSnapshot(system: system, cores: [])
        }
        return nil
    }

    private static func readSystemTicks() -> Ticks? {
        var info = host_cpu_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info>.size / MemoryLayout<integer_t>.size
        )
        let result = withUnsafeMutablePointer(to: &info) { pointer -> kern_return_t in
            pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { rebound in
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, rebound, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return nil
        }
        return ticks(from: info.cpu_ticks)
    }

    private static func readCoreTicks() -> [Ticks]? {
        var cpuInfo: processor_info_array_t?
        var processorCount: natural_t = 0
        var infoCount: mach_msg_type_number_t = 0
        let result = host_processor_info(
            mach_host_self(),
            PROCESSOR_CPU_LOAD_INFO,
            &processorCount,
            &cpuInfo,
            &infoCount
        )
        guard result == KERN_SUCCESS, let cpuInfo else {
            return nil
        }
        defer {
            let bytes = vm_size_t(Int(infoCount) * MemoryLayout<integer_t>.stride)
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: cpuInfo), bytes)
        }

        let states = Int(CPU_STATE_MAX)
        guard states >= 4, processorCount > 0, Int(processorCount) * states <= Int(infoCount) else {
            return nil
        }

        var cores: [Ticks] = []
        cores.reserveCapacity(Int(processorCount))
        for index in 0..<Int(processorCount) {
            let base = index * states
            cores.append(
                Ticks(
                    user: word(cpuInfo[base + Int(CPU_STATE_USER)]),
                    system: word(cpuInfo[base + Int(CPU_STATE_SYSTEM)]),
                    idle: word(cpuInfo[base + Int(CPU_STATE_IDLE)]),
                    nice: word(cpuInfo[base + Int(CPU_STATE_NICE)])
                )
            )
        }
        return cores
    }

    private static func word(_ value: integer_t) -> UInt64 {
        UInt64(UInt32(bitPattern: value))
    }

    /// Host tick fields are a 4-word counter block. Reading the bytes avoids
    /// depending on whether Swift imports the C array as `UInt32` or `Int32`.
    private static func ticks<T>(from value: T) -> Ticks? {
        var value = value
        let words: [UInt32] = withUnsafeBytes(of: &value) { raw in
            guard raw.count >= 16 else {
                return []
            }
            return (0..<4).map { raw.load(fromByteOffset: $0 * 4, as: UInt32.self) }
        }
        guard words.count == 4 else {
            return nil
        }
        return Ticks(
            user: UInt64(words[0]),
            system: UInt64(words[1]),
            idle: UInt64(words[2]),
            nice: UInt64(words[3])
        )
    }

    private struct Percents {
        var total: Double
        var user: Double
        var system: Double
        var idle: Double
    }

    private static func percents(from earlier: Ticks, to later: Ticks) -> Percents? {
        let user = wrappingDelta(later.user, earlier.user)
        let system = wrappingDelta(later.system, earlier.system)
        let idle = wrappingDelta(later.idle, earlier.idle)
        let nice = wrappingDelta(later.nice, earlier.nice)
        let total = user + system + idle + nice
        guard total > 0 else {
            return nil
        }
        func percent(_ part: UInt64) -> Double {
            min(100, max(0, Double(part) / Double(total) * 100))
        }
        return Percents(
            total: percent(user + nice + system),
            user: percent(user + nice),
            system: percent(system),
            idle: percent(idle)
        )
    }

    private static func wrappingDelta(_ later: UInt64, _ earlier: UInt64) -> UInt64 {
        if later >= earlier {
            return later - earlier
        }
        return (UInt64(UInt32.max) - earlier) + 1 + later
    }

    private static func sysctlInt(_ name: String) -> Int? {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else {
            return nil
        }
        return Int(value)
    }

    private static func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 1 else {
            return nil
        }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else {
            return nil
        }
        let text = String(cString: buffer).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }
}

struct CPUReport: Equatable, Sendable {
    var usage: Double?
    var user: Double?
    var system: Double?
    var idle: Double?
    var cores: [Double]
    var performanceCount: Int?
    var efficiencyCount: Int?
    var title: String
    var failed: Bool

    static let waiting = CPUReport(
        usage: nil,
        user: nil,
        system: nil,
        idle: nil,
        cores: [],
        performanceCount: nil,
        efficiencyCount: nil,
        title: "正在识别这台 Mac",
        failed: false
    )
}
