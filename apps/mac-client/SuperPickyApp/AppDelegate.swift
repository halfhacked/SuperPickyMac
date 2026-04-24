import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)

        if ProcessInfo.processInfo.environment["TEST_MODE"] == "1" {
            // Pin the main window to a known frame so XCUITests get a
            // consistent layout across classes running in one xcodebuild
            // invocation. SwiftUI's NSWindow-frame prefs can otherwise
            // carry a narrowed / off-screen window from a prior class
            // into the next, clipping toolbar buttons and sidebar rows.
            // See docs/ci-perf-retry-notes.md.
            DispatchQueue.main.async {
                let frame = NSRect(x: 100, y: 100, width: 1400, height: 900)
                for window in NSApp.windows where window.contentViewController != nil {
                    window.setFrame(frame, display: true)
                }
            }
        }
    }
}
