import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    var processManager: ProcessManager?

    func applicationDidFinishLaunching(_ notification: Notification) {
        processManager?.start()
    }

    func applicationWillTerminate(_ notification: Notification) {
        processManager?.stop()
    }
}
