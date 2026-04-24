import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApplication.shared.activate(ignoringOtherApps: true)

        // GitHub Actions macos-15 (and macos-15-xlarge) hosted runners
        // expose a 1024x768 virtual display. SwiftUI's default 1200-wide
        // window lands at x=-88 on that screen, pushing rightmost
        // toolbar buttons (ThresholdCalibrator, ExifToggle) past the
        // right edge where XCUITest reports them as "not hittable" —
        // see PR #45 diagnostic dump. Under TEST_MODE, force the
        // window to fit fully inside 1024x768 so every toolbar button
        // is on-screen and clickable. Origin y=40 clears the menubar;
        // dispatch async so the WindowGroup has time to create the
        // window.
        if ProcessInfo.processInfo.environment["TEST_MODE"] == "1" {
            DispatchQueue.main.async {
                let frame = NSRect(x: 0, y: 40, width: 1020, height: 700)
                for window in NSApp.windows where window.contentViewController != nil {
                    window.setFrame(frame, display: true)
                }
            }
        }
    }
}
