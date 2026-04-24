import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)

        if ProcessInfo.processInfo.environment["TEST_MODE"] == "1" {
            // Pin the main window WIDE enough that the toolbar never
            // collapses into an overflow menu. A narrow window (<~1500
            // px) drops rightmost toolbar items (ExifToggle /
            // ThresholdCalibratorButton) into a hidden overflow — they
            // remain in the a11y tree but are "not hittable", which
            // shows up as cryptic CI failures. See
            // docs/ci-perf-retry-notes.md. Set in an async block so
            // SwiftUI's WindowGroup has time to create the window.
            DispatchQueue.main.async {
                let frame = NSRect(x: 0, y: 0, width: 1800, height: 1000)
                for window in NSApp.windows where window.contentViewController != nil {
                    window.setFrame(frame, display: true)
                }
            }
        }
    }
}
