import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var processManager: ProcessManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        processManager?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        processManager?.stop()
    }
}
