import XCTest

/// XCUITests for the Settings window: 4 tabs (General, Culling, Bird ID, Advanced)
/// each with a representative control exercised (toggle or slider move or picker).
///
/// Launches once, opens Settings via `⌘,`, switches tabs, touches one control
/// per tab, then closes Settings. The app is left in the empty (no folder)
/// state since Settings doesn't depend on photos.
final class SettingsUITests: XCTestCase {

    static var app: XCUIApplication!

    override class func setUp() {
        super.setUp()
        app = XCUIApplication()
        app.launchEnvironment["TEST_MODE"] = "1"
        app.launchArguments += ["-lastFolderPath", ""]
        app.launch()
        // Wait for main window so ⌘, targets the right app.
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

    /// Opens the Settings window. Idempotent: if already open, returns it.
    @discardableResult
    private func openSettings() -> XCUIElement {
        let app = Self.app!
        let settingsWindow = settingsWindowElement()
        if settingsWindow.exists { return settingsWindow }

        app.typeKey(",", modifierFlags: .command)
        _ = settingsWindow.waitForExistence(timeout: 3)
        return settingsWindow
    }

    /// Resolve the Settings window by its title. macOS uses "Settings" (Ventura+)
    /// or "Preferences" (older). Fall back to any non-main window.
    private func settingsWindowElement() -> XCUIElement {
        let app = Self.app!
        let byTitle = app.windows.matching(NSPredicate(format:
            "title == 'Settings' OR title == 'Preferences' OR title == 'SuperPicky Settings'")).firstMatch
        if byTitle.exists { return byTitle }
        // Fallback: find the window that contains the SettingsTabView hierarchy.
        return app.windows.containing(.any, identifier: "SettingsTabView").firstMatch
    }

    private func closeSettings() {
        let w = settingsWindowElement()
        if w.exists {
            Self.app.typeKey("w", modifierFlags: .command)
            _ = !w.waitForExistence(timeout: 2)
        }
    }

    /// Click a tab by its visible English label. `.tabItem` labels render
    /// as radio-button-style selectors on macOS TabView.
    private func clickTab(_ label: String) {
        let app = Self.app!
        let window = settingsWindowElement()
        let candidates: [XCUIElement] = [
            window.radioButtons[label],
            window.buttons[label],
            window.descendants(matching: .any)[label]
        ]
        for c in candidates where c.exists {
            if c.isHittable { c.click(); Thread.sleep(forTimeInterval: 0.3); return }
        }
        // Last resort: scan the window's accessibility tree.
        let any = app.descendants(matching: .any)[label]
        if any.exists && any.isHittable { any.click() }
        Thread.sleep(forTimeInterval: 0.3)
    }

    // MARK: - Tests

    func test01_OpenSettingsShowsTabs() {
        let app = Self.app!
        let window = openSettings()
        XCTAssertTrue(window.waitForExistence(timeout: 3),
                      "Settings window should open with ⌘,")

        // All four tab labels should exist somewhere in the window.
        for label in ["General", "Culling", "Bird ID", "Advanced"] {
            let present = app.descendants(matching: .any)[label].exists
            XCTAssertTrue(present, "Tab '\(label)' should be present in Settings")
        }
        closeSettings()
    }

    func test02_GeneralTabAutoAdvanceToggle() {
        let app = Self.app!
        openSettings()
        clickTab("General")

        let toggle = app.switches["Auto-advance after rating"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3),
                      "Auto-advance toggle should be visible on General tab")

        // Flip the toggle and flip it back to leave state clean.
        let originalValue = toggle.value as? String
        toggle.click()
        Thread.sleep(forTimeInterval: 0.3)
        let toggledValue = toggle.value as? String
        XCTAssertNotEqual(originalValue, toggledValue,
                          "Toggle value should change after click")
        toggle.click()
        Thread.sleep(forTimeInterval: 0.3)

        closeSettings()
    }

    func test03_CullingTabFlightToggle() {
        let app = Self.app!
        openSettings()
        clickTab("Culling")

        let toggle = app.switches["Enable flight detection"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 3),
                      "Flight-detection toggle should be visible on Culling tab")

        let before = toggle.value as? String
        toggle.click()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertNotEqual(before, toggle.value as? String)
        toggle.click()
        Thread.sleep(forTimeInterval: 0.3)

        closeSettings()
    }

    func test04_BirdIDTabNamingStandardPicker() {
        let app = Self.app!
        openSettings()
        clickTab("Bird ID")

        // The Picker renders as a pop-up button on macOS; accessible name
        // matches the Picker's label.
        let picker = app.popUpButtons["Naming Standard"]
        XCTAssertTrue(picker.waitForExistence(timeout: 3),
                      "Naming Standard picker should be visible on Bird ID tab")
        XCTAssertTrue(picker.isEnabled)

        closeSettings()
    }

    func test05_AdvancedTabSharpnessSliderMoves() {
        let app = Self.app!
        openSettings()
        clickTab("Advanced")

        let valueText = app.staticTexts["SliderRow_Sharpness_Value"]
        XCTAssertTrue(valueText.waitForExistence(timeout: 3),
                      "Sharpness value label should be visible on Advanced tab")

        let before = valueText.label
        let slider = app.sliders["SliderRow_Sharpness_Slider"]
        XCTAssertTrue(slider.exists, "Sharpness slider should exist")

        // macOS sliders normalise to 0..1. Set a value that's clearly different
        // from wherever the user left it: 0.2 and 0.8 are far apart, so at
        // least one of them will change the displayed integer.
        slider.adjust(toNormalizedSliderPosition: 0.2)
        Thread.sleep(forTimeInterval: 0.3)
        let after20 = valueText.label
        slider.adjust(toNormalizedSliderPosition: 0.8)
        Thread.sleep(forTimeInterval: 0.3)
        let after80 = valueText.label

        XCTAssertFalse(before == after20 && before == after80,
                       "Sharpness display should change when slider moves (before=\(before), 0.2=\(after20), 0.8=\(after80))")

        closeSettings()
    }
}
