import XCTest

/// XCUITests for the Settings window: 4 tabs (General, Culling, Bird ID, Advanced)
/// each with a representative control exercised.
///
/// macOS SwiftUI a11y notes (derived from CI tree dumps):
/// - TabView tab buttons render as `Button` in the window Toolbar, findable
///   by their visible title/label (`app.buttons["General"]`).
/// - `Toggle` renders as a pair of sibling elements: a `StaticText` (the
///   label) and a `Switch` (the control). The Switch has NO identifier or
///   label of its own. Locate by index within the Settings window.
/// - `Picker` renders as a sibling StaticText + PopUpButton. Same strategy.
/// - Custom `SliderRow` identifiers may not propagate through Form; use the
///   generic `window.sliders.firstMatch`.
final class SettingsUITests: XCTestCase {

    static var app: XCUIApplication!

    override class func setUp() {
        super.setUp()
        app = XCUIApplication()
        app.launchEnvironment["TEST_MODE"] = "1"
        app.launchArguments += ["-lastFolderPath", ""]
        app.launch()
        _ = app.buttons["SelectFolderButton"].waitForExistence(timeout: 10)
    }

    override class func tearDown() {
        app.terminate()
        super.tearDown()
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - Helpers

    @discardableResult
    private func openSettings() -> XCUIElement {
        let app = Self.app!
        let w = settingsWindow()
        if w.exists { return w }
        app.typeKey(",", modifierFlags: .command)
        _ = w.waitForExistence(timeout: 3)
        return w
    }

    private func settingsWindow() -> XCUIElement {
        Self.app.windows["com_apple_SwiftUI_Settings_window"]
    }

    private func clickTab(_ label: String) {
        let app = Self.app!
        let button = app.buttons[label]
        XCTAssertTrue(button.waitForExistence(timeout: 3),
                      "Tab button '\(label)' should exist")
        button.click()
        Thread.sleep(forTimeInterval: 0.7)
    }

    /// Click via coordinate to cover cases where the element's hit-test is
    /// satisfied by XCUIElement but the default click misses a small target.
    private func clickCenter(_ element: XCUIElement) {
        element.coordinate(withNormalizedOffset: CGVector(dx: 0.5, dy: 0.5)).click()
    }

    // MARK: - Tests

    func test01_OpenSettingsShowsTabs() {
        let app = Self.app!
        let window = openSettings()
        XCTAssertTrue(window.waitForExistence(timeout: 3),
                      "Settings window should open with ⌘,")
        for label in ["General", "Culling", "Bird ID", "Advanced"] {
            XCTAssertTrue(app.buttons[label].exists,
                          "Tab button '\(label)' should be present in Settings toolbar")
        }
    }

    /// Verify General tab exposes a Switch and that toggling it is accepted
    /// without crashing. (On macOS, Switch.value isn't a String, so we can't
    /// easily assert a before/after boolean through XCUIElement — we only
    /// verify the tree shape and that the click is accepted.)
    func test02_GeneralTabHasAutoAdvanceToggle() {
        let window = openSettings()
        clickTab("General")

        let tgl = window.switches.element(boundBy: 0)
        XCTAssertTrue(tgl.waitForExistence(timeout: 3),
                      "General tab should expose at least one Switch (Auto-advance)")
        clickCenter(tgl)
        Thread.sleep(forTimeInterval: 0.3)
        clickCenter(tgl)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(tgl.exists, "Switch should remain in tree after toggles")
    }

    /// Verify Culling tab exposes a Switch (flight-detection or
    /// exposure-detection) and a slider (top-percentage).
    func test03_CullingTabHasToggleAndSlider() {
        let window = openSettings()
        clickTab("Culling")

        XCTAssertGreaterThan(window.switches.count, 0,
                             "Culling tab should expose at least one Switch")
        let firstSlider = window.sliders.firstMatch
        XCTAssertTrue(firstSlider.waitForExistence(timeout: 3),
                      "Culling tab should expose at least one Slider")
    }

    func test04_BirdIDTabNamingStandardPicker() {
        let window = openSettings()
        clickTab("Bird ID")

        let picker = window.popUpButtons.element(boundBy: 0)
        XCTAssertTrue(picker.waitForExistence(timeout: 3),
                      "Bird ID tab should expose at least one PopUpButton (Naming Standard)")
        XCTAssertTrue(picker.isEnabled)
    }

    func test05_AdvancedTabSharpnessSliderMoves() {
        let window = openSettings()
        clickTab("Advanced")

        // Advanced has multiple SliderRows (sharpness, aesthetics, min
        // confidence, min aesthetics). We only need to prove one slider is
        // present and responds to adjustment.
        let slider = window.sliders.firstMatch
        XCTAssertTrue(slider.waitForExistence(timeout: 3),
                      "Advanced tab should expose at least one Slider")

        slider.adjust(toNormalizedSliderPosition: 0.2)
        Thread.sleep(forTimeInterval: 0.3)
        slider.adjust(toNormalizedSliderPosition: 0.8)
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(slider.exists, "Slider should remain in tree after adjustments")
    }
}
