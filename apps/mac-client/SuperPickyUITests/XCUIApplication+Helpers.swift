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
        _ = images["PhotoPreview"].waitForExistence(timeout: timeout)
        Thread.sleep(forTimeInterval: 1)
    }
}
