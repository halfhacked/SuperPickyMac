import XCTest

/// XCUITests for the Threshold Calibrator popover (toolbar slider-icon button).
final class CalibratorUITests: XCTestCase {

    static var app: XCUIApplication!
    static var testDir: String!

    override class func setUp() {
        super.setUp()

        testDir = NSTemporaryDirectory() + "superpicky_calibrator_\(UUID().uuidString.prefix(8))"
        try? FileManager.default.removeItem(atPath: testDir)
        try! FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)

        let thisFile = URL(fileURLWithPath: #filePath)
        let projectRoot = thisFile
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let sourceDir = projectRoot.appendingPathComponent("test-photos").path

        if FileManager.default.fileExists(atPath: sourceDir) {
            let photos = try! FileManager.default.contentsOfDirectory(atPath: sourceDir)
                .filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".ARW") }
            for photo in photos {
                try! FileManager.default.copyItem(
                    atPath: (sourceDir as NSString).appendingPathComponent(photo),
                    toPath: (testDir as NSString).appendingPathComponent(photo)
                )
            }
        }

        app = XCUIApplication()
        app.launchEnvironment["TEST_MODE"] = "1"
        app.launchEnvironment["TEST_FOLDER"] = testDir
        app.launch()

        _ = app.images.firstMatch.waitForExistence(timeout: 15)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if app.progressIndicators.count == 0 { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        Thread.sleep(forTimeInterval: 1)
    }

    override class func tearDown() {
        app.terminate()
        try? FileManager.default.removeItem(atPath: testDir)
        super.tearDown()
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func calibratorButton() -> XCUIElement {
        Self.app.buttons.matching(identifier: "ThresholdCalibratorButton").firstMatch
    }

    private func dismissPopover() {
        // Click far into the main preview area to dismiss without hitting
        // any other control. Brief sleep to let macOS animate the popover out.
        Self.app.images["PhotoPreview"].click()
        Thread.sleep(forTimeInterval: 0.5)
    }

    // MARK: - Tests

    func test01_CalibratorButtonExists() {
        let button = calibratorButton()
        XCTAssertTrue(button.waitForExistence(timeout: 10),
                      "Threshold calibrator toolbar button should exist")
        XCTAssertTrue(button.isEnabled)
    }

    /// Clicking the calibrator button opens a popover containing at least
    /// two sliders (Sharpness and Aesthetics).
    func test02_ClickOpensPopoverWithTwoSliders() {
        let app = Self.app!
        calibratorButton().click()
        Thread.sleep(forTimeInterval: 0.5)

        // The popover's sliders don't carry our custom SliderRow identifiers
        // because ThresholdScoreRow is a separate custom row. Query the raw
        // Slider count instead — the main content view doesn't have any
        // sliders, so any sliders found are the calibrator popover's.
        let deadline = Date().addingTimeInterval(3)
        var count = app.sliders.count
        while Date() < deadline && count < 2 {
            Thread.sleep(forTimeInterval: 0.2)
            count = app.sliders.count
        }
        XCTAssertGreaterThanOrEqual(count, 2,
                                    "Calibrator popover should surface >= 2 sliders (got \(count))")

        dismissPopover()
    }

    /// Moving the popover's first slider leaves the popover on screen and
    /// the slider element intact.
    func test03_SliderMoves() {
        let app = Self.app!
        calibratorButton().click()
        Thread.sleep(forTimeInterval: 0.5)

        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 3),
                      "At least one slider should be visible in the popover")

        slider.adjust(toNormalizedSliderPosition: 0.2)
        Thread.sleep(forTimeInterval: 0.3)
        slider.adjust(toNormalizedSliderPosition: 0.8)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(slider.exists, "Slider should remain in the tree after adjust")

        dismissPopover()
    }

    func test04_ClickingOutsideDismissesPopover() {
        let app = Self.app!
        calibratorButton().click()
        Thread.sleep(forTimeInterval: 0.5)

        let slider = app.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 3))

        dismissPopover()
        Thread.sleep(forTimeInterval: 0.5)

        // After dismissal the slider element should be gone.
        XCTAssertFalse(app.sliders.firstMatch.exists,
                       "Calibrator slider should not be in the a11y tree after dismissal")
    }
}
