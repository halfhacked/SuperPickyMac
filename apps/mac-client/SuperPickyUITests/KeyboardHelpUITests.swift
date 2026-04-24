import XCTest

/// XCUITests for the Keyboard Shortcuts help overlay (? key).
final class KeyboardHelpUITests: SuperPickyUITestCase {

    override class var testDirPrefix: String { "superpicky_kbdhelp" }

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    func test01_QuestionMarkOpensHelp() {
        let app = Self.app!
        let preview = app.images[A11y.photoPreview]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.click()
        Thread.sleep(forTimeInterval: 0.3)

        // ? is Shift+/ — XCUIApplication.typeText sends the literal char
        // which is how ContentView.handleKey dispatches ("?" case).
        app.typeText("?")
        Thread.sleep(forTimeInterval: 0.4)

        let overlay = app.descendants(matching: .any)["KeyboardHelpOverlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 2),
                      "? should open the keyboard help overlay")
    }

    func test02_AnyKeyDismissesHelp() {
        let app = Self.app!
        let overlay = app.descendants(matching: .any)["KeyboardHelpOverlay"]
        if !overlay.exists {
            // Re-open from clean state
            app.images[A11y.photoPreview].click()
            Thread.sleep(forTimeInterval: 0.2)
            app.typeText("?")
            _ = overlay.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(overlay.exists, "Overlay should be present before dismissal")

        // handleKey dismisses on *any* key press when showKeyboardHelp is set.
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertFalse(overlay.exists, "Any key should dismiss the keyboard help overlay")
    }
}
