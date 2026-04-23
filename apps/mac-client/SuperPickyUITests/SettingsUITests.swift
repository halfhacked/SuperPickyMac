import XCTest

/// XCUITests for the Settings window: 4 tabs (General, Culling, Bird ID, Advanced)
/// each with a representative control exercised.
///
/// macOS SwiftUI `Toggle` renders as `.checkBox`, `Picker` as `.popUpButton`,
/// and `TabView` tabs surface as `.radioButton` in the XCUIElement tree.
/// Clicking a tab requires a proper radio-button/button match — clicking a
/// stray descendant with the matching label does not switch tabs.
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
        let settingsWindow = settingsWindowElement()
        if settingsWindow.exists { return settingsWindow }
        app.typeKey(",", modifierFlags: .command)
        _ = settingsWindow.waitForExistence(timeout: 3)
        return settingsWindow
    }

    private func settingsWindowElement() -> XCUIElement {
        let app = Self.app!
        let byTitle = app.windows.matching(NSPredicate(format:
            "title == 'Settings' OR title == 'Preferences' OR title == 'SuperPicky Settings'")).firstMatch
        if byTitle.exists { return byTitle }
        return app.windows.containing(.any, identifier: "SettingsTabView").firstMatch
    }

    private func closeSettings() {
        let w = settingsWindowElement()
        if w.exists {
            Self.app.typeKey("w", modifierFlags: .command)
            _ = !w.waitForExistence(timeout: 2)
        }
    }

    /// Click a Settings tab. Tries radioButton → button → tab element types,
    /// then falls back to a coordinate click at the expected tab-bar slot.
    /// `index` is 0-based: General=0, Culling=1, Bird ID=2, Advanced=3.
    private func clickTab(_ label: String, index: Int) {
        let app = Self.app!
        let window = settingsWindowElement()

        let predicate = NSPredicate(format: "label == %@ OR identifier == %@", label, label)
        let queries: [XCUIElementQuery] = [
            window.radioButtons.matching(predicate),
            window.buttons.matching(predicate),
            window.tabs.matching(predicate)
        ]
        for q in queries {
            let el = q.firstMatch
            if el.exists && el.isHittable {
                el.click()
                Thread.sleep(forTimeInterval: 0.5)
                return
            }
        }

        // Coordinate fallback: tab bar sits just under the window title bar.
        // Four tabs split the width evenly; target the centre of each slot.
        let tabX: CGFloat = 0.125 + 0.25 * CGFloat(index)
        let tabY: CGFloat = 0.10
        if window.exists {
            window.coordinate(withNormalizedOffset: CGVector(dx: tabX, dy: tabY)).click()
        } else {
            app.coordinate(withNormalizedOffset: CGVector(dx: tabX, dy: tabY)).click()
        }
        Thread.sleep(forTimeInterval: 0.5)
    }

    /// Locate a Toggle on macOS — default style renders as `.checkBox`.
    private func toggle(named label: String) -> XCUIElement {
        let app = Self.app!
        let byIdentifier = app.checkBoxes[label]
        if byIdentifier.exists { return byIdentifier }
        let byLabel = app.checkBoxes.matching(NSPredicate(format: "label == %@", label)).firstMatch
        if byLabel.exists { return byLabel }
        // Final fallback: switches (iOS-style Toggle explicitly set via
        // `.toggleStyle(.switch)`).
        let asSwitch = app.switches.matching(NSPredicate(format: "label == %@ OR identifier == %@", label, label)).firstMatch
        return asSwitch
    }

    private func picker(named label: String) -> XCUIElement {
        let app = Self.app!
        let byIdentifier = app.popUpButtons[label]
        if byIdentifier.exists { return byIdentifier }
        return app.popUpButtons.matching(NSPredicate(format: "label == %@", label)).firstMatch
    }

    // MARK: - Tests

    func test01_OpenSettingsShowsTabs() {
        let app = Self.app!
        let window = openSettings()
        XCTAssertTrue(window.waitForExistence(timeout: 3),
                      "Settings window should open with ⌘,")

        // Diagnostic dump: print the whole a11y tree once so CI logs show
        // the element types/identifiers we need to target on this macOS
        // runner. Remove after SettingsUITests is stable.
        print("=== Settings a11y tree (diagnostic) ===\n\(window.debugDescription)\n=== end tree ===")
        print("=== Entire app a11y tree ===\n\(app.debugDescription)\n=== end app tree ===")

        for label in ["General", "Culling", "Bird ID", "Advanced"] {
            XCTAssertTrue(app.descendants(matching: .any)[label].exists,
                          "Tab '\(label)' should be present in Settings")
        }
        closeSettings()
    }

    /// General is the default tab — no navigation required. Verifies the
    /// Auto-advance checkBox is present and flip-able.
    func test02_GeneralTabAutoAdvanceToggle() {
        openSettings()
        clickTab("General", index: 0)

        let tgl = toggle(named: "Auto-advance after rating")
        XCTAssertTrue(tgl.waitForExistence(timeout: 3),
                      "Auto-advance toggle should be visible on General tab")

        let before = tgl.value as? String
        tgl.click()
        Thread.sleep(forTimeInterval: 0.3)
        let after = tgl.value as? String
        XCTAssertNotEqual(before, after, "Toggle value should change after click")
        tgl.click()
        Thread.sleep(forTimeInterval: 0.3)
        closeSettings()
    }

    func test03_CullingTabFlightToggle() {
        openSettings()
        clickTab("Culling", index: 1)

        let tgl = toggle(named: "Enable flight detection")
        XCTAssertTrue(tgl.waitForExistence(timeout: 3),
                      "Flight-detection toggle should be visible on Culling tab")
        let before = tgl.value as? String
        tgl.click()
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertNotEqual(before, tgl.value as? String)
        tgl.click()
        Thread.sleep(forTimeInterval: 0.3)
        closeSettings()
    }

    func test04_BirdIDTabNamingStandardPicker() {
        openSettings()
        clickTab("Bird ID", index: 2)

        let p = picker(named: "Naming Standard")
        XCTAssertTrue(p.waitForExistence(timeout: 3),
                      "Naming Standard picker should be visible on Bird ID tab")
        XCTAssertTrue(p.isEnabled)
        closeSettings()
    }

    func test05_AdvancedTabSharpnessSliderMoves() {
        let app = Self.app!
        openSettings()
        clickTab("Advanced", index: 3)

        let valueText = app.staticTexts["SliderRow_Sharpness_Value"]
        XCTAssertTrue(valueText.waitForExistence(timeout: 3),
                      "Sharpness value label should be visible on Advanced tab")

        let before = valueText.label
        let slider = app.sliders["SliderRow_Sharpness_Slider"]
        XCTAssertTrue(slider.exists, "Sharpness slider should exist")

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
