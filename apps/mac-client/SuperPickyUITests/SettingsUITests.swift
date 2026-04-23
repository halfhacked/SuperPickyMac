import XCTest

/// XCUITests for the Settings window: 4 tabs (General, Culling, Bird ID, Advanced)
/// each with a representative control exercised.
///
/// macOS SwiftUI a11y notes (derived from on-CI tree dumps):
/// - TabView tab buttons render as `Button` in the window Toolbar, findable
///   by their visible title/label (`app.buttons["General"]`).
/// - `Toggle` renders as a pair of sibling elements: a `StaticText` (the
///   label) and a `Switch` (the control). The Switch has NO identifier or
///   label of its own. We therefore locate toggles by index within the
///   Settings window (`window.switches.element(boundBy: 0)` == first toggle
///   on the currently-selected tab).
/// - `Picker` renders as a sibling StaticText + PopUpButton. Same strategy.
/// - Sliders from our custom `SliderRow` carry explicit identifiers
///   (`SliderRow_<label>_Slider` / `_Value`).
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
        Thread.sleep(forTimeInterval: 0.5)
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

    func test02_GeneralTabAutoAdvanceToggle() {
        let window = openSettings()
        clickTab("General")

        // General tab's first Switch is the Auto-advance toggle.
        let tgl = window.switches.element(boundBy: 0)
        XCTAssertTrue(tgl.waitForExistence(timeout: 3),
                      "General tab should expose at least one Switch")

        let before = tgl.value as? String
        tgl.click()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertNotEqual(before, tgl.value as? String,
                          "Switch value should change after click")
        tgl.click()
        Thread.sleep(forTimeInterval: 0.3)
    }

    func test03_CullingTabFlightToggle() {
        let window = openSettings()
        clickTab("Culling")

        // Culling tab has: exposure-detection Toggle, (conditional) exposure
        // threshold slider, flight-detection Toggle, top-percentage slider.
        // At least one Switch must be present.
        let toggles = window.switches
        XCTAssertGreaterThan(toggles.count, 0,
                             "Culling tab should expose at least one Switch")

        let first = toggles.element(boundBy: 0)
        let before = first.value as? String
        first.click()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertNotEqual(before, first.value as? String)
        first.click()
        Thread.sleep(forTimeInterval: 0.3)
    }

    func test04_BirdIDTabNamingStandardPicker() {
        let window = openSettings()
        clickTab("Bird ID")

        // First PopUpButton on Bird ID tab is the Naming Standard picker.
        let picker = window.popUpButtons.element(boundBy: 0)
        XCTAssertTrue(picker.waitForExistence(timeout: 3),
                      "Bird ID tab should expose at least one PopUpButton")
        XCTAssertTrue(picker.isEnabled)
    }

    func test05_AdvancedTabSharpnessSliderMoves() {
        let app = Self.app!
        let window = openSettings()
        clickTab("Advanced")

        // SliderRow applies a custom identifier; search the app for it
        // (the value text lives inside the Settings window but any-descendant
        // search on the app works too).
        let valueText = app.staticTexts["SliderRow_Sharpness_Value"]
        XCTAssertTrue(valueText.waitForExistence(timeout: 3),
                      "Sharpness value label should be visible on Advanced tab")

        let before = valueText.label
        let slider = app.sliders["SliderRow_Sharpness_Slider"]
        XCTAssertTrue(slider.exists, "Sharpness slider should exist")

        slider.adjust(toNormalizedSliderPosition: 0.2)
        Thread.sleep(forTimeInterval: 0.3)
        let at20 = valueText.label
        slider.adjust(toNormalizedSliderPosition: 0.8)
        Thread.sleep(forTimeInterval: 0.3)
        let at80 = valueText.label

        XCTAssertFalse(before == at20 && before == at80,
                       "Sharpness display should change (before=\(before), 0.2=\(at20), 0.8=\(at80))")

        // Restore to a value close to the default so repeated CI runs of
        // this shared-app class don't accumulate drift.
        slider.adjust(toNormalizedSliderPosition: 0.5)
        Thread.sleep(forTimeInterval: 0.3)
        _ = window
    }
}
