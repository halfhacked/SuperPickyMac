import XCTest

/// BDD: Keyboard shortcut tests — rating keys (0-5), fullscreen toggle, and fullscreen key handling.
/// Verifies the focus management fixes: ContentView auto-focuses on appear so rating/fullscreen
/// keys fire immediately, and FullscreenViewer grabs focus on appear so its keys (Escape, arrows,
/// 0-5) fire correctly.
///
/// Each test launches its own app instance in mock mode for isolation.
final class KeyboardShortcutUITests: XCTestCase {

    // MARK: - Helpers

    /// Launch app with mock inference and freshly copied test photos; wait for processing to finish.
    private func launchWithProcessedPhotos() -> XCUIApplication {
        let testDir = Self.copyTestPhotos()
        let app = XCUIApplication()
        app.launchEnvironment["TEST_MODE"] = "1"
        app.launchEnvironment["TEST_FOLDER"] = testDir
        app.launch()

        // Wait for thumbnails (mock inference is instant)
        _ = app.images.firstMatch.waitForExistence(timeout: 15)

        // Wait for progress indicators to clear
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if app.progressIndicators.count == 0 { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        // Let UI fully settle
        Thread.sleep(forTimeInterval: 1)

        return app
    }

    private static func copyTestPhotos() -> String {
        let testDir = NSTemporaryDirectory() + "superpicky_kbd_bdd_\(UUID().uuidString.prefix(8))"
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
                let src = (sourceDir as NSString).appendingPathComponent(photo)
                let dst = (testDir as NSString).appendingPathComponent(photo)
                try! FileManager.default.copyItem(atPath: src, toPath: dst)
            }
        }

        return testDir
    }

    // MARK: - Main View Rating Shortcuts (0-5)

    /// Pressing "5" in the main content view applies a manual 5-star rating.
    /// Verifies: ContentView receives key events via its @FocusState auto-focus.
    func testMainViewRating_PressFive_AppliesManualRating() throws {
        let app = launchWithProcessedPhotos()
        defer { app.terminate() }

        let preview = app.images["PhotoPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10),
                      "Photo preview must be visible before testing keyboard shortcuts")

        // Fresh mock-processed photos have AI ratings (isManualRating = false) — no pencil yet
        XCTAssertFalse(app.images["ManualRatingIndicator"].exists,
                       "ManualRatingIndicator should not exist before any key press")

        // Click preview to ensure the window is key and ContentView has focus
        preview.click()
        app.typeKey("5", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(app.images["ManualRatingIndicator"].waitForExistence(timeout: 3),
                      "ManualRatingIndicator (pencil) should appear after pressing '5'")

        let ratingEl = app.descendants(matching: .any)["InfoBarRating"]
        if ratingEl.waitForExistence(timeout: 2) {
            XCTAssertEqual(ratingEl.value as? String, "5",
                           "InfoBarRating value should be '5' after pressing '5'")
        }
    }

    /// Pressing "0" in the main view applies a zero/reject rating.
    func testMainViewRating_PressZero_AppliesRejectRating() throws {
        let app = launchWithProcessedPhotos()
        defer { app.terminate() }

        let preview = app.images["PhotoPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))

        preview.click()
        app.typeKey("0", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(app.images["ManualRatingIndicator"].waitForExistence(timeout: 3),
                      "ManualRatingIndicator should appear after pressing '0'")

        let ratingEl = app.descendants(matching: .any)["InfoBarRating"]
        if ratingEl.waitForExistence(timeout: 2) {
            XCTAssertEqual(ratingEl.value as? String, "0",
                           "InfoBarRating value should be '0' after pressing '0'")
        }
    }

    /// Pressing "3" in the main view applies a 3-star rating.
    func testMainViewRating_PressThree_SetsThreeStarRating() throws {
        let app = launchWithProcessedPhotos()
        defer { app.terminate() }

        let preview = app.images["PhotoPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))

        preview.click()
        app.typeKey("3", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(app.images["ManualRatingIndicator"].waitForExistence(timeout: 3),
                      "ManualRatingIndicator should appear after pressing '3'")

        let ratingEl = app.descendants(matching: .any)["InfoBarRating"]
        if ratingEl.waitForExistence(timeout: 2) {
            XCTAssertEqual(ratingEl.value as? String, "3",
                           "InfoBarRating value should be '3' after pressing '3'")
        }
    }

    // MARK: - Fullscreen Toggle

    /// Pressing "f" from the main content view enters fullscreen mode.
    /// Verifies: ContentView's onKeyPress("f") fires via @FocusState auto-focus.
    func testFullscreen_PressF_EntersFullscreen() throws {
        let app = launchWithProcessedPhotos()
        defer { app.terminate() }

        let preview = app.images["PhotoPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))

        XCTAssertFalse(app.otherElements["FullscreenViewer"].exists,
                       "FullscreenViewer should not be present before pressing 'f'")

        preview.click()
        app.typeKey("f", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(app.otherElements["FullscreenViewer"].waitForExistence(timeout: 3),
                      "FullscreenViewer should appear after pressing 'f'")

        // Clean up
        app.typeKey(.escape, modifierFlags: [])
    }

    // MARK: - Fullscreen Keys

    /// Pressing Escape while fullscreen is open closes it.
    /// Verifies: FullscreenViewer's onKeyPress(.escape) fires via its @FocusState auto-focus.
    func testFullscreen_Escape_ExitsFullscreen() throws {
        let app = launchWithProcessedPhotos()
        defer { app.terminate() }

        let preview = app.images["PhotoPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))

        // Enter fullscreen
        preview.click()
        app.typeKey("f", modifierFlags: [])
        XCTAssertTrue(app.otherElements["FullscreenViewer"].waitForExistence(timeout: 3),
                      "FullscreenViewer must open before testing Escape")

        // Press Escape
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertFalse(app.otherElements["FullscreenViewer"].exists,
                       "FullscreenViewer should be dismissed after pressing Escape")
        XCTAssertTrue(app.images["PhotoPreview"].exists,
                      "Photo preview should be accessible again after exiting fullscreen")
    }

    /// Pressing right and left arrow keys in fullscreen navigates without crashing.
    /// Verifies: FullscreenViewer's arrow key handlers fire after it grabs focus on appear.
    func testFullscreen_ArrowKeys_Navigate() throws {
        let app = launchWithProcessedPhotos()
        defer { app.terminate() }

        let preview = app.images["PhotoPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))

        // Enter fullscreen
        preview.click()
        app.typeKey("f", modifierFlags: [])
        let fsViewer = app.otherElements["FullscreenViewer"]
        XCTAssertTrue(fsViewer.waitForExistence(timeout: 3),
                      "FullscreenViewer must open before testing arrow keys")

        // Navigate forward then back — neither should crash
        app.typeKey(.rightArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.leftArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        // Fullscreen should still be open after navigation
        XCTAssertTrue(fsViewer.exists,
                      "FullscreenViewer should remain open after arrow key navigation")

        app.typeKey(.escape, modifierFlags: [])
    }

    /// Pressing a digit key while in fullscreen applies a manual rating to the selected photo.
    /// Verifies: FullscreenViewer's onKeyPress("4") fires and calls onRatePhoto.
    func testFullscreen_RatingKey_AppliesRating() throws {
        let app = launchWithProcessedPhotos()
        defer { app.terminate() }

        let preview = app.images["PhotoPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))

        // Enter fullscreen
        preview.click()
        app.typeKey("f", modifierFlags: [])
        XCTAssertTrue(app.otherElements["FullscreenViewer"].waitForExistence(timeout: 3),
                      "FullscreenViewer must open before testing rating keys")

        // Rate with "4" from inside fullscreen
        app.typeKey("4", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        // Exit fullscreen — main view InfoBar should now reflect the manual rating
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(app.images["ManualRatingIndicator"].waitForExistence(timeout: 3),
                      "ManualRatingIndicator should appear after rating with '4' in fullscreen")

        let ratingEl = app.descendants(matching: .any)["InfoBarRating"]
        if ratingEl.waitForExistence(timeout: 2) {
            XCTAssertEqual(ratingEl.value as? String, "4",
                           "InfoBarRating value should be '4' after pressing '4' in fullscreen")
        }
    }
}
