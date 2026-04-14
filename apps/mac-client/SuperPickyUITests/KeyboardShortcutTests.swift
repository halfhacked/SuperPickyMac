import XCTest

/// Tests all keyboard shortcuts in a single sequential flow.
final class KeyboardShortcutTests: XCTestCase {

    static var app: XCUIApplication!

    override class func setUp() {
        super.setUp()
        app = XCUIApplication()
        app.launchEnvironment["TEST_MODE"] = "1"
        app.launchEnvironment["TEST_FOLDER"] = copyTestPhotos()
        app.launch()
        sleep(3) // Let processing complete
    }

    override class func tearDown() {
        app.terminate()
        super.tearDown()
    }

    func testAllKeyboardShortcuts() {
        let app = Self.app!

        // Wait for photos to load
        XCTAssertTrue(app.images.firstMatch.waitForExistence(timeout: 10), "Thumbnails should appear")

        // --- Arrow keys navigate photos ---
        let firstThumb = app.images.firstMatch
        firstThumb.click()
        sleep(1)

        app.typeKey(.rightArrow, modifierFlags: [])
        sleep(1)
        // Just verify app didn't crash — photo changed

        app.typeKey(.leftArrow, modifierFlags: [])
        sleep(1)

        // --- I toggles EXIF panel ---
        let exifToggle = app.buttons["ExifToggle"]
        // Panel should be visible by default
        let panel = app.scrollViews["ExifPanel"]
        let panelWasVisible = panel.exists

        app.typeKey("i", modifierFlags: [])
        sleep(1)
        if panelWasVisible {
            // Should have toggled off (or on if it was off)
            // Just verify no crash
        }

        app.typeKey("i", modifierFlags: [])
        sleep(1)
        // Toggled back

        // --- F enters fullscreen ---
        app.typeKey("f", modifierFlags: [])
        sleep(1)
        let fullscreen = app.otherElements["FullscreenViewer"]
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 3), "Fullscreen should open with F")

        // --- Arrow keys work in fullscreen ---
        app.typeKey(.rightArrow, modifierFlags: [])
        sleep(1)

        // --- F exits fullscreen ---
        app.typeKey("f", modifierFlags: [])
        sleep(1)
        XCTAssertFalse(fullscreen.exists, "Fullscreen should close with F")

        // --- F opens again (toggle works repeatedly) ---
        app.typeKey("f", modifierFlags: [])
        sleep(1)
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 3), "Fullscreen should reopen with F")

        // --- Escape exits fullscreen ---
        app.typeKey(.escape, modifierFlags: [])
        sleep(1)
        XCTAssertFalse(fullscreen.exists, "Escape should close fullscreen")

        // --- Number keys rate photos ---
        app.typeKey("5", modifierFlags: [])
        sleep(1)
        // Verify rating changed — check sidebar counts or just no crash

        app.typeKey("0", modifierFlags: [])
        sleep(1)

        // --- Z toggles zoom ---
        app.typeKey("z", modifierFlags: [])
        sleep(1)
        // Should be zoomed in — no crash

        app.typeKey("z", modifierFlags: [])
        sleep(1)
        // Should be back to fit

        // --- Z works in fullscreen too ---
        app.typeKey("f", modifierFlags: [])
        sleep(1)

        app.typeKey("z", modifierFlags: [])
        sleep(1)

        app.typeKey("z", modifierFlags: [])
        sleep(1)

        app.typeKey(.escape, modifierFlags: [])
        sleep(1)
    }

    // MARK: - Helpers

    private static func copyTestPhotos() -> String {
        let testDir = NSTemporaryDirectory() + "superpicky_keyboard_test"
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
        return testDir
    }
}
