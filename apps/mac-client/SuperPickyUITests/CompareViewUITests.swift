import XCTest

/// XCUITests for the side-by-side compare mode (C key).
/// Uses a single shared app instance with processed test photos.
final class CompareViewUITests: SuperPickyUITestCase {

    override class var testDirPrefix: String { "superpicky_compare" }

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func ensureCompareClosed() {
        let app = Self.app!
        if app.descendants(matching: .any)["CompareView"].exists {
            app.typeKey(.escape, modifierFlags: [])
            Thread.sleep(forTimeInterval: 0.4)
        }
    }

    // MARK: - Tests

    func test01_CKeyOpensCompare() {
        let app = Self.app!
        // Make sure we're focused on the main window.
        let preview = app.images[A11y.photoPreview]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.click()
        Thread.sleep(forTimeInterval: 0.3)

        app.typeKey("c", modifierFlags: [])

        let compare = app.descendants(matching: .any)["CompareView"]
        XCTAssertTrue(compare.waitForExistence(timeout: 3),
                      "C key should open compare view")
        ensureCompareClosed()
    }

    func test02_EscapeClosesCompare() {
        let app = Self.app!
        let preview = app.images[A11y.photoPreview]
        preview.click()
        app.typeKey("c", modifierFlags: [])
        let compare = app.descendants(matching: .any)["CompareView"]
        XCTAssertTrue(compare.waitForExistence(timeout: 3))

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(compare.exists, "Escape should close compare view")
    }

    func test03_CKeyTogglesCompare() {
        let app = Self.app!
        let preview = app.images[A11y.photoPreview]
        preview.click()
        app.typeKey("c", modifierFlags: [])
        let compare = app.descendants(matching: .any)["CompareView"]
        XCTAssertTrue(compare.waitForExistence(timeout: 3))

        // C again exits (per CompareView.handleKey)
        app.typeKey("c", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(compare.exists, "Second C should close compare view")
    }

    func test04_ArrowKeysNavigateInCompare() {
        let app = Self.app!
        let preview = app.images[A11y.photoPreview]
        preview.click()
        app.typeKey("c", modifierFlags: [])
        let compare = app.descendants(matching: .any)["CompareView"]
        XCTAssertTrue(compare.waitForExistence(timeout: 3))

        // Arrows shouldn't crash / shouldn't exit compare.
        app.typeKey(.rightArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        app.typeKey(.leftArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(compare.exists, "Compare should survive arrow navigation")

        ensureCompareClosed()
    }

    func test05_RatingKeysInCompare() {
        let app = Self.app!
        let preview = app.images[A11y.photoPreview]
        preview.click()
        app.typeKey("c", modifierFlags: [])
        let compare = app.descendants(matching: .any)["CompareView"]
        XCTAssertTrue(compare.waitForExistence(timeout: 3))

        // Rating key on active side should not crash the view.
        app.typeKey("3", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(compare.exists, "Compare should survive rating keystroke")

        ensureCompareClosed()
    }
}
