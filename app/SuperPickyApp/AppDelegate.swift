import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var isUITest: Bool {
        ProcessInfo.processInfo.environment["TEST_MODE"] == "1"
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        if isUITest {
            NSApplication.shared.setActivationPolicy(.regular)
        }
    }

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
        // window. Wait for WindowGroup to create its window before promoting
        // it to key/foreground; activating too early can leave XCUITest
        // seeing Running Background.
        if isUITest {
            waitForUITestWindow(until: .now() + .seconds(10))
        }
    }

    private func waitForUITestWindow(until deadline: DispatchTime) {
        if let window = NSApp.windows.first(where: {
            $0.contentViewController != nil && $0.canBecomeMain
        }) {
            window.setFrame(NSRect(x: 0, y: 40, width: 1020, height: 700), display: true)
            window.makeKeyAndOrderFront(nil)
            NSApplication.shared.activate(ignoringOtherApps: true)
            return
        }

        guard DispatchTime.now().uptimeNanoseconds < deadline.uptimeNanoseconds else {
            NSLog("SuperPicky UI test window did not appear within 10 seconds")
            return
        }

        DispatchQueue.main.asyncAfter(deadline: .now() + .milliseconds(50)) { [weak self] in
            self?.waitForUITestWindow(until: deadline)
        }
    }
}
