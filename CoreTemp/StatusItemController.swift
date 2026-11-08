import AppKit
import Combine
import SwiftUI
import os

@MainActor
final class StatusItemController: NSObject, NSPopoverDelegate {
    private let statusItem: NSStatusItem
    private let popover = NSPopover()
    private let monitor: SystemMonitor
    private var cancellable: AnyCancellable?
    private var globalMonitor: Any?
    private var escapeMonitor: Any?

    override init() {
        // Create the status item immediately so the bar shows even if later setup fails.
        let item = NSStatusBar.system.statusItem(withLength: 232)
        self.statusItem = item
        self.monitor = SystemMonitor()
        super.init()

        item.isVisible = true
        if let button = item.button {
            button.target = self
            button.action = #selector(togglePopover)
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
            button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
            button.title = "芯温"
            button.toolTip = "芯温"
            let image = NSImage(systemSymbolName: "thermometer.medium", accessibilityDescription: "芯温")
            image?.isTemplate = true
            button.image = image
            button.imagePosition = .imageLeading
        }
        Self.log("status item created, button=\(item.button != nil)")

        popover.behavior = .applicationDefined
        popover.animates = true
        popover.delegate = self
        popover.contentSize = NSSize(width: 324, height: 428)
        let host = NSHostingController(rootView: PopoverView(monitor: monitor))
        host.sizingOptions = [.preferredContentSize]
        popover.contentViewController = host

        cancellable = monitor.$snapshot
            .receive(on: DispatchQueue.main)
            .sink { [weak self] snapshot in
                self?.render(snapshot)
            }
        render(monitor.snapshot)
        monitor.start()
        Self.log("monitor started")
    }

    private static func log(_ message: String) {
        let line = "\(Date()) \(message)\n"
        let path = NSHomeDirectory() + "/Library/Logs/CoreTemp.log"
        if let data = line.data(using: .utf8) {
            if FileManager.default.fileExists(atPath: path),
               let handle = FileHandle(forWritingAtPath: path) {
                handle.seekToEndOfFile()
                handle.write(data)
                try? handle.close()
            } else {
                FileManager.default.createFile(atPath: path, contents: data)
            }
        }
    }

    @objc private func togglePopover() {
        if popover.isShown {
            popover.performClose(nil)
        } else {
            showPopover()
        }
    }

    private func showPopover() {
        guard let button = statusItem.button else { return }
        popover.show(relativeTo: button.bounds, of: button, preferredEdge: .minY)
        DispatchQueue.main.async { [weak self] in
            self?.popover.contentViewController?.view.window?.makeKey()
        }
        if globalMonitor == nil {
            globalMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                DispatchQueue.main.async { self?.popover.performClose(nil) }
            }
        }
        if escapeMonitor == nil {
            escapeMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
                if event.keyCode == 53 {
                    self?.popover.performClose(nil)
                    return nil
                }
                return event
            }
        }
    }

    func popoverDidClose(_ notification: Notification) {
        if let globalMonitor {
            NSEvent.removeMonitor(globalMonitor)
            self.globalMonitor = nil
        }
        if let escapeMonitor {
            NSEvent.removeMonitor(escapeMonitor)
            self.escapeMonitor = nil
        }
    }

    private func render(_ snapshot: Snapshot) {
        guard let button = statusItem.button else { return }
        statusItem.isVisible = true
        button.font = NSFont.monospacedDigitSystemFont(ofSize: NSFont.systemFontSize, weight: .medium)
        button.title = MenuText.title(for: snapshot)
        button.setAccessibilityLabel(MenuText.accessibility(for: snapshot))
    }
}

enum MenuText {
    static func title(for snapshot: Snapshot) -> String {
        // Fixed-width fields keep the status item from shifting as values change.
        "\(temperature(snapshot)) \(usage(snapshot)) \(network(snapshot))    \(gpu(snapshot))"
    }

    static func accessibility(for snapshot: Snapshot) -> String {
        let temp: String
        if let celsius = snapshot.temperature.headline?.celsius {
            temp = String(format: "温度 %.0f 度", celsius)
        } else if snapshot.isLoading {
            temp = "温度读取中"
        } else {
            temp = "没有温度"
        }
        let cpu: String
        if let usage = snapshot.cpu.usage {
            cpu = String(format: "占用 %.0f%%", usage)
        } else if snapshot.cpu.failed {
            cpu = "没有占用"
        } else {
            cpu = "占用采样中"
        }
        return "芯温，\(temp)，\(cpu)，\(networkAccessibility(snapshot))，\(gpuAccessibility(snapshot))"
    }

    private static func temperature(_ snapshot: Snapshot) -> String {
        if snapshot.isLoading { return " …°" }
        if let celsius = snapshot.temperature.headline?.celsius {
            return String(format: "%3.0f°", celsius)
        }
        return " --°"
    }

    private static func usage(_ snapshot: Snapshot) -> String {
        if snapshot.isLoading || (snapshot.cpu.usage == nil && !snapshot.cpu.failed) {
            return " …%"
        }
        if let usage = snapshot.cpu.usage {
            return String(format: "%3.0f%%", usage)
        }
        return " --%"
    }

    private static func network(_ snapshot: Snapshot) -> String {
        let report = snapshot.network
        if snapshot.isLoading || (report.downloadBytesPerSecond == nil && report.uploadBytesPerSecond == nil && !report.failed) {
            return "↓  …  ↑  … "
        }
        if report.failed {
            return "↓  --  ↑  -- "
        }
        let down = NetworkReport.formatRateFixed(report.downloadBytesPerSecond ?? 0)
        let up = NetworkReport.formatRateFixed(report.uploadBytesPerSecond ?? 0)
        return "↓\(down) ↑\(up)"
    }

    private static func gpu(_ snapshot: Snapshot) -> String {
        if snapshot.isLoading || snapshot.gpu.active == .unknown {
            return "显卡"
        }
        return snapshot.gpu.active.shortLabel
    }

    private static func networkAccessibility(_ snapshot: Snapshot) -> String {
        let report = snapshot.network
        if snapshot.isLoading || (report.downloadBytesPerSecond == nil && report.uploadBytesPerSecond == nil && !report.failed) {
            return "网速采样中"
        }
        if report.failed {
            return "没有网速"
        }
        let down = NetworkReport.formatRateDetailed(report.downloadBytesPerSecond ?? 0)
        let up = NetworkReport.formatRateDetailed(report.uploadBytesPerSecond ?? 0)
        return "下载 \(down)，上传 \(up)"
    }

    private static func gpuAccessibility(_ snapshot: Snapshot) -> String {
        if snapshot.isLoading {
            return "显卡识别中"
        }
        return snapshot.gpu.detail
    }
}
