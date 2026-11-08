import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var statusController: StatusItemController?

    private func log(_ message: String) {
        let line = "\(Date()) \(message)\n"
        let paths = [
            "/tmp/coretemp.log",
            NSHomeDirectory() + "/Desktop/coretemp.log"
        ]
        if let data = line.data(using: .utf8) {
            for path in paths {
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
        NSLog("CoreTemp: %@", message)
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        log("willFinishLaunching home=\(NSHomeDirectory())")
        NSApp.setActivationPolicy(.regular)
        installMenu()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        log("didFinishLaunching")
        statusController = StatusItemController()
        log("statusController ready")
    }

    private func installMenu() {
        let main = NSMenu()
        let appItem = NSMenuItem()
        main.addItem(appItem)
        let appMenu = NSMenu(title: "芯温")
        appItem.submenu = appMenu
        let about = NSMenuItem(title: "关于芯温", action: #selector(showAbout(_:)), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        appMenu.addItem(.separator())
        let quit = NSMenuItem(title: "退出芯温", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenu.addItem(quit)
        NSApp.mainMenu = main
    }

    @objc private func showAbout(_ sender: Any?) {
        NSApp.activate()
        NSApp.orderFrontStandardAboutPanel(options: [:])
    }
}
