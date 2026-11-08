import AppKit
import SwiftUI

struct PopoverView: View {
    @ObservedObject var monitor: SystemMonitor
    @State private var revealDetails = false
    @State private var showAllSensors = false

    var body: some View {
        ScrollView(.vertical, showsIndicators: true) {
            VStack(alignment: .leading, spacing: 0) {
                header
                stats
                    .padding(.top, 12)
                networkStats
                    .padding(.top, 8)
                memoryAndGPU
                    .padding(.top, 8)
                diskStats
                    .padding(.top, 8)
                if let usage = monitor.snapshot.cpu.usage {
                    usageBar(usage)
                        .padding(.top, 12)
                }
                if !monitor.snapshot.cpu.cores.isEmpty {
                    cores
                        .padding(.top, 14)
                }
                sensors
                    .padding(.top, 14)
                footer
                    .padding(.top, 14)
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .frame(width: 324, height: 428)
        .onAppear { monitor.refreshLoginStatus() }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("芯温")
                .font(.headline)
            Text(machineLine)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var machineLine: String {
        let cpu = monitor.snapshot.cpu
        if let performance = cpu.performanceCount, let efficiency = cpu.efficiencyCount, performance > 0, efficiency > 0 {
            return "\(cpu.title) · \(performance) 性能核 · \(efficiency) 能效核"
        }
        if !cpu.cores.isEmpty {
            return "\(cpu.title) · \(cpu.cores.count) 个逻辑处理器"
        }
        return cpu.title
    }

    private var stats: some View {
        HStack(spacing: 8) {
            StatCard(
                symbol: "thermometer.medium",
                label: "温度",
                value: temperatureValue,
                valueColor: temperatureColor,
                footnote: temperatureFootnote
            )
            StatCard(
                symbol: "cpu",
                label: "占用",
                value: usageValue,
                valueColor: .primary,
                footnote: usageFootnote
            )
        }
    }

    private var networkStats: some View {
        HStack(spacing: 8) {
            StatCard(
                symbol: "arrow.down.circle",
                label: "下载",
                value: downloadValue,
                valueColor: .primary,
                footnote: "实时下行"
            )
            StatCard(
                symbol: "arrow.up.circle",
                label: "上传",
                value: uploadValue,
                valueColor: .primary,
                footnote: "实时上行"
            )
        }
    }

    private var downloadValue: String {
        networkValue(monitor.snapshot.network.downloadBytesPerSecond)
    }

    private var uploadValue: String {
        networkValue(monitor.snapshot.network.uploadBytesPerSecond)
    }

    private func networkValue(_ rate: Double?) -> String {
        if monitor.snapshot.isLoading {
            return "…"
        }
        if monitor.snapshot.network.failed {
            return "—"
        }
        guard let rate else {
            return "…"
        }
        return NetworkReport.formatRateDetailed(rate)
    }

    private var memoryAndGPU: some View {
        HStack(spacing: 8) {
            StatCard(
                symbol: "memorychip",
                label: "内存",
                value: memoryValue,
                valueColor: memoryColor,
                footnote: memoryFootnote
            )
            StatCard(
                symbol: gpuSymbol,
                label: "显卡",
                value: gpuValue,
                valueColor: gpuColor,
                footnote: gpuFootnote
            )
        }
    }

    private var memoryValue: String {
        if monitor.snapshot.isLoading {
            return "…"
        }
        if monitor.snapshot.memory.failed {
            return "—"
        }
        guard let percent = monitor.snapshot.memory.usagePercent else {
            return "…"
        }
        return String(format: "%.0f%%", percent)
    }

    private var memoryColor: Color {
        switch monitor.snapshot.memory.pressure {
        case .serious:
            return Color(red: 0.86, green: 0.27, blue: 0.22)
        case .warning:
            return Color(red: 0.84, green: 0.46, blue: 0.18)
        default:
            return .primary
        }
    }

    private var memoryFootnote: String {
        let memory = monitor.snapshot.memory
        if monitor.snapshot.isLoading {
            return "正在读取内存"
        }
        if memory.failed {
            return "没有读到内存"
        }
        guard let used = memory.usedBytes else {
            return "采样中"
        }
        let pressure: String
        switch memory.pressure {
        case .serious: pressure = "压力高"
        case .warning: pressure = "偏紧"
        case .normal: pressure = "正常"
        case .unknown: pressure = "—"
        }
        return "已用 \(MemoryReport.formatBytes(used)) / \(MemoryReport.formatBytes(memory.totalBytes)) · \(pressure)"
    }

    private var gpuValue: String {
        if monitor.snapshot.isLoading {
            return "…"
        }
        if monitor.snapshot.gpu.failed {
            return "—"
        }
        return monitor.snapshot.gpu.active.shortLabel
    }

    private var gpuSymbol: String {
        switch monitor.snapshot.gpu.active {
        case .discrete:
            return "bolt.circle"
        case .integrated:
            return "cpu"
        case .unknown:
            return "questionmark.circle"
        }
    }

    private var gpuColor: Color {
        switch monitor.snapshot.gpu.active {
        case .discrete:
            return Color(red: 0.84, green: 0.46, blue: 0.18)
        default:
            return .primary
        }
    }

    private var gpuFootnote: String {
        if monitor.snapshot.isLoading {
            return "正在识别显卡"
        }
        return monitor.snapshot.gpu.detail
    }

    private var diskStats: some View {
        HStack(spacing: 8) {
            StatCard(
                symbol: "internaldrive",
                label: "总容量",
                value: diskTotalValue,
                valueColor: .primary,
                footnote: diskVolumeFootnote
            )
            StatCard(
                symbol: "externaldrive.badge.checkmark",
                label: "剩余",
                value: diskFreeValue,
                valueColor: diskFreeColor,
                footnote: diskUsedFootnote
            )
        }
    }

    private var diskTotalValue: String {
        if monitor.snapshot.isLoading {
            return "…"
        }
        guard let total = monitor.snapshot.disk.totalBytes, !monitor.snapshot.disk.failed else {
            return monitor.snapshot.disk.failed ? "—" : "…"
        }
        return DiskReport.formatBytes(total)
    }

    private var diskFreeValue: String {
        if monitor.snapshot.isLoading {
            return "…"
        }
        guard let free = monitor.snapshot.disk.freeBytes, !monitor.snapshot.disk.failed else {
            return monitor.snapshot.disk.failed ? "—" : "…"
        }
        return DiskReport.formatBytes(free)
    }

    private var diskFreeColor: Color {
        guard let percent = monitor.snapshot.disk.usedPercent else {
            return .primary
        }
        if percent >= 90 {
            return Color(red: 0.86, green: 0.27, blue: 0.22)
        }
        if percent >= 80 {
            return Color(red: 0.84, green: 0.46, blue: 0.18)
        }
        return .primary
    }

    private var diskVolumeFootnote: String {
        if monitor.snapshot.isLoading {
            return "正在读取磁盘"
        }
        if monitor.snapshot.disk.failed {
            return "没有读到系统盘"
        }
        return monitor.snapshot.disk.volumeName ?? "系统盘"
    }

    private var diskUsedFootnote: String {
        if monitor.snapshot.isLoading {
            return "采样中"
        }
        if monitor.snapshot.disk.failed {
            return "—"
        }
        guard let used = monitor.snapshot.disk.usedBytes, let percent = monitor.snapshot.disk.usedPercent else {
            return "采样中"
        }
        return "已用 \(DiskReport.formatBytes(used)) · \(String(format: "%.0f%%", percent))"
    }

    private var temperatureValue: String {
        if monitor.snapshot.isLoading {
            return "…"
        }
        if let celsius = monitor.snapshot.temperature.headline?.celsius {
            return String(format: "%.1f°", celsius)
        }
        return "—"
    }

    private var temperatureColor: Color {
        guard let celsius = monitor.snapshot.temperature.headline?.celsius else {
            return .primary
        }
        if celsius >= 95 {
            return Color(red: 0.86, green: 0.27, blue: 0.22)
        }
        if celsius >= 80 {
            return Color(red: 0.84, green: 0.46, blue: 0.18)
        }
        return .primary
    }

    private var temperatureFootnote: String {
        if monitor.snapshot.isLoading {
            return "正在读取传感器"
        }
        guard let headline = monitor.snapshot.temperature.headline else {
            return "没有确认到 CPU 温度"
        }
        return "\(headline.sourceName) · \(headline.sensorName)\n\(headline.detail)"
    }

    private var usageValue: String {
        if monitor.snapshot.isLoading || (monitor.snapshot.cpu.usage == nil && !monitor.snapshot.cpu.failed) {
            return "…"
        }
        guard let usage = monitor.snapshot.cpu.usage else {
            return "—"
        }
        if usage > 0 && usage < 10 {
            return String(format: "%.1f%%", usage)
        }
        return String(format: "%.0f%%", usage)
    }

    private var usageFootnote: String {
        let cpu = monitor.snapshot.cpu
        if monitor.snapshot.isLoading || (cpu.usage == nil && !cpu.failed) {
            return "占用要等一个刷新间隔"
        }
        if cpu.failed {
            return "没读到 CPU 计数器"
        }
        let user = cpu.user ?? 0
        let system = cpu.system ?? 0
        let idle = cpu.idle ?? 0
        return String(format: "用户 %.0f%% · 系统 %.0f%%\n空闲 %.0f%%", user, system, idle)
    }

    private func usageBar(_ usage: Double) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(usageColor(usage))
                        .frame(width: max(4, geo.size.width * CGFloat(min(100, max(0, usage))) / 100))
                }
            }
            .frame(height: 6)
        }
    }

    private var cores: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("核心")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                Spacer()
                Text("按系统顺序")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
            }
            if monitor.snapshot.cpu.cores.count > 8 {
                ScrollView {
                    coreGrid
                }
                .frame(height: 156)
            } else {
                coreGrid
            }
        }
    }

    private var coreGrid: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 6), count: 4), spacing: 6) {
            ForEach(Array(monitor.snapshot.cpu.cores.enumerated()), id: \.offset) { index, value in
                CoreCell(index: index + 1, usage: value)
            }
        }
    }

    private var sensors: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("传感器")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            sensorBody
        }
    }

    @ViewBuilder
    private var sensorBody: some View {
        let report = monitor.snapshot.temperature
        if monitor.snapshot.isLoading {
            Text("正在枚举传感器…")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if report.sensors.isEmpty && report.headline == nil {
            Text("没有读到可以确认的 CPU 温度。下面是系统实际返回的内容，菜单栏不会填一个猜测值。")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            diagnostics
        } else {
            let visible = showAllSensors ? report.sensors : Array(report.sensors.prefix(6))
            VStack(alignment: .leading, spacing: 5) {
                ForEach(visible) { sensor in
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Text(sensor.sourceName)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .frame(width: 32, alignment: .leading)
                        Text(sensor.title)
                            .font(.caption)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer(minLength: 8)
                        Text(String(format: "%.1f°", sensor.celsius))
                            .font(.caption.monospacedDigit())
                    }
                }
            }
            if report.sensors.count > 6 {
                Button(showAllSensors ? "收起" : "其余 \(report.sensors.count - 6) 个") {
                    showAllSensors.toggle()
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            if report.headline == nil {
                Text("这些读数里没有能确认的 CPU 传感器，所以菜单栏温度保持为 --°。")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                diagnostics
            }
        }
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 8) {
            Divider()
            Text("刷新间隔")
                .font(.caption)
                .foregroundStyle(.secondary)
            Picker("刷新间隔", selection: intervalBinding) {
                Text("1 秒").tag(1.0)
                Text("2 秒").tag(2.0)
                Text("5 秒").tag(5.0)
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .controlSize(.small)

            Toggle("登录时打开", isOn: loginBinding)
                .font(.callout)
                .controlSize(.small)
            if let caption = loginCaption {
                Text(caption)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack {
                if monitor.snapshot.temperature.headline != nil || monitor.snapshot.isLoading {
                    Button(revealDetails ? "收起详情" : "读取详情") {
                        revealDetails.toggle()
                    }
                    .buttonStyle(.borderless)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                }
                Spacer()
                Button("退出") {
                    NSApp.terminate(nil)
                }
                .buttonStyle(.borderless)
                .font(.caption)
                .foregroundStyle(.secondary)
                .keyboardShortcut("q", modifiers: .command)
            }
            if detailsVisible {
                diagnostics
            }
        }
    }

    private var detailsVisible: Bool {
        let report = monitor.snapshot.temperature
        if report.headline == nil && !monitor.snapshot.isLoading {
            return false
        }
        return revealDetails
    }

    private var diagnostics: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("HID：\(monitor.snapshot.temperature.hidSummary)")
            Text("SMC：\(monitor.snapshot.temperature.smcSummary)")
            if !monitor.snapshot.temperature.unclassified.isEmpty {
                Text("未归类，因此没有当成 CPU：")
                ForEach(Array(monitor.snapshot.temperature.unclassified.enumerated()), id: \.offset) { _, line in
                    Text(line)
                }
                if monitor.snapshot.temperature.unclassifiedExtra > 0 {
                    Text("还有 \(monitor.snapshot.temperature.unclassifiedExtra) 个")
                }
            }
            Text(monitor.snapshot.temperature.headline == nil
                 ? "没有选出 CPU 温度，菜单栏会保持 --°。"
                 : "菜单栏上的温度就是选出的那一个传感器，不是估算值。")
        }
        .font(.caption2)
        .foregroundStyle(.secondary)
        .textSelection(.enabled)
        .frame(maxWidth: .infinity, alignment: .leading)
        .fixedSize(horizontal: false, vertical: true)
    }

    private var intervalBinding: Binding<Double> {
        Binding(
            get: { monitor.refreshInterval },
            set: { monitor.setRefreshInterval($0) }
        )
    }

    private var loginBinding: Binding<Bool> {
        Binding(
            get: {
                monitor.loginStatus == .enabled || monitor.loginStatus == .requiresApproval
            },
            set: { monitor.setLoginEnabled($0) }
        )
    }

    private var loginCaption: String? {
        if let message = monitor.loginMessage, !message.isEmpty {
            return message
        }
        switch monitor.loginStatus {
        case .enabled:
            return nil
        case .requiresApproval:
            return "请到「系统设置 → 通用 → 登录项与扩展」允许芯温。"
        case .notRegistered:
            return "打开后，登录时菜单栏会自动出现这项。"
        case .notFound:
            return "请把 CoreTemp.app 放到「应用程序」文件夹后再打开一次。"
        @unknown default:
            return nil
        }
    }

    private func usageColor(_ usage: Double) -> Color {
        if usage >= 90 {
            return Color(red: 0.86, green: 0.27, blue: 0.22)
        }
        if usage >= 70 {
            return Color(red: 0.84, green: 0.46, blue: 0.18)
        }
        return Color.primary.opacity(0.72)
    }
}

private struct StatCard: View {
    var symbol: String
    var label: String
    var value: String
    var valueColor: Color
    var footnote: String

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 4) {
                Image(systemName: symbol)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(label)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(value)
                .font(.system(size: 26, weight: .medium, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(valueColor)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
            Text(footnote)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
        }
        .frame(maxWidth: .infinity, minHeight: 96, alignment: .topLeading)
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(Color.primary.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(Color.primary.opacity(0.06), lineWidth: 1)
        )
    }
}

private struct CoreCell: View {
    var index: Int
    var usage: Double

    var body: some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 2) {
                Text("\(index)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer(minLength: 0)
                Text(String(format: "%.0f%%", usage))
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.primary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.08))
                    Capsule()
                        .fill(Color.primary.opacity(usage >= 85 ? 0.85 : 0.45))
                        .frame(width: max(2, geo.size.width * CGFloat(min(100, max(0, usage))) / 100))
                }
            }
            .frame(height: 3)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .fill(Color.primary.opacity(0.04))
        )
    }
}

#if DEBUG
#Preview {
    PopoverView(monitor: .preview)
}
#endif
