import XCTest

extension XCUIApplication {
    /// Block until the shared-app setUp handshake finishes: at least one
    /// image has appeared, the progress bar is gone, and — crucially on CI,
    /// where full-res decode of the ~3 MB fixture JPGs lags — the auto-
    /// selected photo's PhotoPreview has entered the a11y tree. Anything
    /// that clicks PhotoPreview or assumes a rendered preview should
    /// `await` this before running.
    func waitUntilProcessed(timeout: TimeInterval = 15) {
        _ = images.firstMatch.waitForExistence(timeout: timeout)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if progressIndicators.count == 0 { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        _ = images[A11y.photoPreview].waitForExistence(timeout: timeout)
        Thread.sleep(forTimeInterval: 1)
    }

    /// Open a popup menu, retrying the center-coordinate interaction until
    /// XCTest can observe an expected item. Hosted macOS runners occasionally
    /// drop the first menu click even though the control is hittable.
    func openMenu(
        from control: XCUIElement,
        exposing menuItem: XCUIElement,
        attempts: Int = 3,
        timeout: TimeInterval = 2
    ) -> Bool {
        retryMenuInteraction(on: control, exposing: menuItem, attempts: attempts, timeout: timeout) {
            $0.click()
        }
    }

    /// Open a context menu through a coordinate-level right click. Hovering
    /// first and retrying after Escape avoids dropped right-click events on
    /// hosted runners without hiding a menu that genuinely never appears.
    func openContextMenu(
        on target: XCUIElement,
        exposing menuItem: XCUIElement,
        attempts: Int = 3,
        timeout: TimeInterval = 2
    ) -> Bool {
        retryMenuInteraction(on: target, exposing: menuItem, attempts: attempts, timeout: timeout) {
            $0.rightClick()
        }
    }

    private func retryMenuInteraction(
        on target: XCUIElement,
        exposing menuItem: XCUIElement,
        attempts: Int,
        timeout: TimeInterval,
        interaction: (XCUICoordinate) -> Void
    ) -> Bool {
        guard attempts > 0, target.waitForExistence(timeout: timeout) else { return false }

        for attempt in 0..<attempts {
            if attempt > 0 {
                typeKey(.escape, modifierFlags: [])
                activate()
                Thread.sleep(forTimeInterval: 0.15)
            }

            let center = target.coordinate(
                withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)
            )
            center.hover()
            Thread.sleep(forTimeInterval: 0.1)
            interaction(center)

            if menuItem.waitForExistence(timeout: timeout) {
                return true
            }
        }
        return false
    }
}
