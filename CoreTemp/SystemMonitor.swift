import AppKit
import os
import ServiceManagement

struct Snapshot: Equatable, Sendable {
    var isLoading: Bool
    var temperature: TemperatureReport
    var cpu: CPUReport
    var network: NetworkReport
    var memory: MemoryReport
    var gpu: GPUReport
    var disk: DiskReport
    var battery: BatteryReport

    static let loading = Snapshot(
        isLoading: true,
        temperature: .empty,
        cpu: .waiting,
        network: .waiting,
        memory: .waiting,
        gpu: .waiting,
        disk: .waiting,
        battery: .waiting
    )
}

@MainActor
final class SystemMonitor: ObservableObject {
    @Published private(set) var snapshot: Snapshot = .loading
    @Published private(set) var refreshInterval: TimeInterval
    @Published private(set) var loginStatus: SMAppService.Status
    @Published private(set) var loginMessage: String?

    private let sampler = SensorSampler()
    private let logger = Logger(subsystem: "app.coretemp.CoreTemp", category: "sensors")
    private var timer: Timer?
    private var started = false
    private var wakeToken: NSObjectProtocol?
    private var lastLoggedProblem: String?

    init() {
        let stored = UserDefaults.standard.double(forKey: "refreshInterval")
        refreshInterval = [1.0, 2.0, 5.0].contains(stored) ? stored : 2
        // Ad-hoc signed builds can throw when querying login item status too early.
        loginStatus = .notFound
        DispatchQueue.main.async { [weak self] in
            self?.loginStatus = SMAppService.mainApp.status
        }
    }

    func start() {
        guard !started else {
            return
        }
        started = true
        wakeToken = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            Task { @MainActor in
                self?.handleWake()
            }
        }
        refresh()
        reschedule()
    }

    func setRefreshInterval(_ value: TimeInterval) {
        let next: TimeInterval
        if value < 1.5 {
            next = 1
        } else if value < 3.5 {
            next = 2
        } else {
            next = 5
        }
        guard next != refreshInterval else {
            return
        }
        refreshInterval = next
        UserDefaults.standard.set(next, forKey: "refreshInterval")
        reschedule()
    }

    func refreshLoginStatus() {
        loginStatus = SMAppService.mainApp.status
    }

    func setLoginEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            loginMessage = nil
        } catch {
            loginMessage = "没能更新登录项：\(error.localizedDescription)"
        }
        refreshLoginStatus()
    }

    private func handleWake() {
        sampler.reset()
        refresh()
    }

    private func refresh() {
        sampler.sample { [weak self] sample in
            Task { @MainActor in
                self?.apply(sample)
            }
        }
    }

    private func apply(_ sample: Sample) {
        let next = Snapshot(isLoading: false, temperature: sample.temperature, cpu: sample.cpu, network: sample.network, memory: sample.memory, gpu: sample.gpu, disk: sample.disk, battery: sample.battery)
        guard next != snapshot else {
            return
        }
        snapshot = next
        logTemperatureGap(next)
    }

    private func logTemperatureGap(_ snapshot: Snapshot) {
        guard snapshot.temperature.headline == nil else {
            lastLoggedProblem = nil
            return
        }
        let problem = "\(snapshot.temperature.hidSummary) | \(snapshot.temperature.smcSummary)"
        guard problem != lastLoggedProblem else {
            return
        }
        lastLoggedProblem = problem
        logger.error("CPU temperature unavailable: \(problem, privacy: .public)")
    }

    private func reschedule() {
        timer?.invalidate()
        timer = nil
        guard started else {
            return
        }
        let timer = Timer(timeInterval: refreshInterval, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

#if DEBUG
    /// Xcode canvas only. The running app never uses these numbers.
    static var preview: SystemMonitor {
        let monitor = SystemMonitor()
        monitor.snapshot = Snapshot(
            isLoading: false,
            temperature: TemperatureReport(
                headline: TemperatureHeadline(
                    celsius: 72.4,
                    sourceName: "HID",
                    sensorName: "PMU tdie3",
                    detail: "同组平均 64.1°"
                ),
                sensors: [
                    ListedSensor(id: "h1", sourceName: "HID", name: "PMU tdie3", note: nil, celsius: 72.4),
                    ListedSensor(id: "h2", sourceName: "HID", name: "PMU tdie1", note: nil, celsius: 61.2),
                    ListedSensor(id: "e1", sourceName: "HID", name: "eACC MTR Temp Sensor0", note: nil, celsius: 48.6)
                ],
                hidSummary: "读到 3 个",
                smcSummary: "没有 AppleSMC 服务。较新的 Apple Silicon 系统常常如此，温度改看 HID。",
                unclassified: [],
                unclassifiedExtra: 0
            ),
            cpu: CPUReport(
                usage: 34,
                user: 22,
                system: 12,
                idle: 66,
                cores: [40, 22, 81, 6, 15, 9, 4, 7],
                performanceCount: 6,
                efficiencyCount: 2,
                title: "Apple M3 Pro",
                failed: false
            ),
            network: .waiting,
            memory: .waiting,
            gpu: .waiting,
            disk: DiskReport(
                totalBytes: 1_000_000_000_000,
                freeBytes: 420_000_000_000,
                volumeName: "Macintosh HD",
                failed: false
            ),
            battery: BatteryReport(
                percent: 65,
                mode: .charging,
                onAC: true,
                timeToEmptyMinutes: nil,
                timeToFullMinutes: 92,
                cycleCount: 150,
                watts: 48,
                present: true,
                failed: false
            )
        )
        return monitor
    }
#endif
}

private struct Sample: Sendable {
    var temperature: TemperatureReport
    var cpu: CPUReport
    var network: NetworkReport
    var memory: MemoryReport
    var gpu: GPUReport
    var disk: DiskReport
    var battery: BatteryReport
}

private final class SensorSampler: @unchecked Sendable {
    private let queue = DispatchQueue(label: "app.coretemp.sensors", qos: .utility)
    private let cpu = CPUUsageReader()
    private let network = NetworkSpeedReader()
    private let memory = MemoryReader()
    private let gpu = GPUActivityReader()
    private let disk = DiskSpaceReader()
    private let battery = BatteryReader()

    func reset() {
        queue.async {
            SensorClose()
            self.cpu.reset()
            self.network.reset()
        }
    }

    func sample(_ completion: @escaping @Sendable (Sample) -> Void) {
        queue.async {
            let sample = Sample(
                temperature: TemperatureService.read(),
                cpu: self.cpu.sample(),
                network: self.network.sample(),
                memory: self.memory.sample(),
                gpu: self.gpu.sample(),
                disk: self.disk.sample(),
                battery: self.battery.sample()
            )
            completion(sample)
        }
    }
}
