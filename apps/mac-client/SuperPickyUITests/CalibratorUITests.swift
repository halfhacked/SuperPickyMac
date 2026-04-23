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
                .filter { $0.hasSuffix(".jpg") }
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
        // On macOS CI, toolbar buttons surface as a nested Button→Button
        // pair sharing the identifier; .firstMatch picks the outer one.
        Self.app.buttons.matching(identifier: "ThresholdCalibratorButton").firstMatch
    }

    private func dismissPopover() {
        // Clicking anywhere outside the popover dismisses it. The photo
        // preview is a large, reliably hittable target.
        Self.app.images["PhotoPreview"].click()
        Thread.sleep(forTimeInterval: 0.3)
    }

    // MARK: - Tests

    func test01_CalibratorButtonExists() {
        let button = calibratorButton()
        XCTAssertTrue(button.waitForExistence(timeout: 10),
                      "Threshold calibrator toolbar button should exist")
        XCTAssertTrue(button.isEnabled)
    }

    func test02_ClickOpensPopoverWithBothSliders() {
        let app = Self.app!
        calibratorButton().click()

        // The popover's content includes both labeled sliders by identifier.
        let sharpness = app.sliders["SliderRow_Sharpness_Slider"]
        let aesthetics = app.sliders["SliderRow_Aesthetics_Slider"]
        XCTAssertTrue(sharpness.waitForExistence(timeout: 3),
                      "Sharpness slider should be visible in calibrator popover")
        XCTAssertTrue(aesthetics.exists,
                      "Aesthetics slider should be visible in calibrator popover")

        dismissPopover()
    }

    func test03_SharpnessSliderMovesValue() {
        let app = Self.app!
        calibratorButton().click()

        let valueText = app.staticTexts["SliderRow_Sharpness_Value"]
        XCTAssertTrue(valueText.waitForExistence(timeout: 3))

        let before = valueText.label
        let slider = app.sliders["SliderRow_Sharpness_Slider"]

        slider.adjust(toNormalizedSliderPosition: 0.1)
        Thread.sleep(forTimeInterval: 0.3)
        let at10 = valueText.label
        slider.adjust(toNormalizedSliderPosition: 0.9)
        Thread.sleep(forTimeInterval: 0.3)
        let at90 = valueText.label

        XCTAssertFalse(before == at10 && before == at90,
                       "Sharpness display should change after slider adjustment (before=\(before), 10%=\(at10), 90%=\(at90))")

        dismissPopover()
    }

    func test04_ClickingOutsideDismissesPopover() {
        let app = Self.app!
        calibratorButton().click()

        let slider = app.sliders["SliderRow_Sharpness_Slider"]
        XCTAssertTrue(slider.waitForExistence(timeout: 3))

        dismissPopover()
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(slider.exists,
                       "Calibrator popover slider should not be in the a11y tree after dismissal")
    }
}
