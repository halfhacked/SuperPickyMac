import XCTest

/// BDD: Culling enhancement features — mock mode with processed photos.
/// Each test launches its own app instance (MockUITests-style).
final class CullingEnhancementUITests: XCTestCase {

    // MARK: - Helpers

    /// Launch app in mock mode with test photos, wait for processing to complete.
    private func launchWithProcessedPhotos() -> XCUIApplication {
        let testDir = Self.copyTestPhotos()
        let app = XCUIApplication()
        app.launchEnvironment["TEST_MODE"] = "1"
        app.launchEnvironment["TEST_FOLDER"] = testDir
        app.launch()

        // Wait for thumbnails to appear (mock inference is instant)
        let thumbnail = app.images.firstMatch
        _ = thumbnail.waitForExistence(timeout: 15)

        // Wait for progress indicators to disappear
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if app.progressIndicators.count == 0 { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        // Let UI settle
        Thread.sleep(forTimeInterval: 1)

        return app
    }

    /// Launch app in mock mode without a test folder (empty state).
    private func launchEmpty() -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TEST_MODE"] = "1"
        app.launch()
        return app
    }

    private static func copyTestPhotos() -> String {
        let testDir = NSTemporaryDirectory() + "superpicky_culling_bdd_\(UUID().uuidString.prefix(8))"
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

    // MARK: - Rating Scale UI

    /// Sidebar shows all 6 rating labels.
    func testRatingScale_AllSixLabelsExist() throws {
        let app = launchEmpty()
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["Excellent"].waitForExistence(timeout: 5),
                       "Excellent label should exist")
        XCTAssertTrue(app.staticTexts["Good"].exists, "Good label should exist")
        XCTAssertTrue(app.staticTexts["Average"].exists, "Average label should exist")
        XCTAssertTrue(app.staticTexts["Below Average"].exists, "Below Average label should exist")
        XCTAssertTrue(app.staticTexts["Poor"].exists, "Poor label should exist")
        XCTAssertTrue(app.staticTexts["Reject"].exists, "Reject label should exist")
    }

    /// Sidebar rating labels appear in correct top-to-bottom order (5→0).
    func testRatingScale_LabelsInDescendingOrder() throws {
        let app = launchEmpty()
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["Excellent"].waitForExistence(timeout: 5))

        let excellent = app.staticTexts["Excellent"]
        let good = app.staticTexts["Good"]
        let average = app.staticTexts["Average"]
        let belowAverage = app.staticTexts["Below Average"]
        let poor = app.staticTexts["Poor"]
        let reject = app.staticTexts["Reject"]

        // Each label should be above the next (lower Y = higher on screen)
        XCTAssertLessThan(excellent.frame.minY, good.frame.minY,
                          "Excellent should be above Good")
        XCTAssertLessThan(good.frame.minY, average.frame.minY,
                          "Good should be above Average")
        XCTAssertLessThan(average.frame.minY, belowAverage.frame.minY,
                          "Average should be above Below Average")
        XCTAssertLessThan(belowAverage.frame.minY, poor.frame.minY,
                          "Below Average should be above Poor")
        XCTAssertLessThan(poor.frame.minY, reject.frame.minY,
                          "Poor should be above Reject")
    }

    // MARK: - Manual Rating in Fullscreen

    /// Enter fullscreen mode and press a rating key — verify fullscreen works and InfoBar exists.
    func testManualRating_FullscreenAndRateKey() throws {
        let app = launchWithProcessedPhotos()
        defer { app.terminate() }

        // Verify a photo is displayed (preview exists)
        let preview = app.images["PhotoPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10),
                       "Photo preview should be visible after processing")

        // Enter fullscreen with "f" key
        app.typeKey("f", modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)

        // Press "5" to rate as Excellent
        app.typeKey("5", modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)

        // InfoBar should still be visible in fullscreen
        let infoBar = app.otherElements["InfoBar"]
        XCTAssertTrue(infoBar.waitForExistence(timeout: 5),
                       "InfoBar should be visible in fullscreen after rating")

        // Exit fullscreen with Escape
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
    }

    /// After manual rating, pencil icon (ManualRatingIndicator) appears.
    func testManualRating_PencilIconAppears() throws {
        let app = launchWithProcessedPhotos()
        defer { app.terminate() }

        let preview = app.images["PhotoPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))

        // Enter fullscreen
        app.typeKey("f", modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)

        // Rate with "3" key
        app.typeKey("3", modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)

        // ManualRatingIndicator (pencil icon) should appear
        let pencil = app.images["ManualRatingIndicator"]
        XCTAssertTrue(pencil.waitForExistence(timeout: 5),
                       "Pencil icon should appear after manual rating override")

        // Exit fullscreen
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 1)
    }

    // MARK: - Export Button

    /// Export button exists in toolbar.
    func testExportButton_ExistsInToolbar() throws {
        let app = launchWithProcessedPhotos()
        defer { app.terminate() }

        let exportButton = app.buttons["ExportButton"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 10),
                       "Export button should exist in toolbar")
    }

    /// Export button is enabled and clickable (does not crash on click).
    func testExportButton_IsClickable() throws {
        let app = launchWithProcessedPhotos()
        defer { app.terminate() }

        let exportButton = app.buttons["ExportButton"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 10))
        XCTAssertTrue(exportButton.isEnabled, "Export button should be enabled")

        // Click the export button — it will open a folder picker, but at least it
        // shouldn't crash. We dismiss any dialog that appears.
        exportButton.click()
        Thread.sleep(forTimeInterval: 1)

        // Press Escape to dismiss any file dialog
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        // App should still be running
        XCTAssertTrue(app.staticTexts["Excellent"].exists,
                       "App should remain functional after clicking Export")
    }

    // MARK: - Zoom

    /// Preview area shows a photo after processing.
    func testZoom_PreviewShowsPhoto() throws {
        let app = launchWithProcessedPhotos()
        defer { app.terminate() }

        let preview = app.images["PhotoPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10),
                       "Preview area should show a photo after processing")
    }

    /// Double-click on preview does not crash (basic zoom smoke test).
    func testZoom_DoubleClickDoesNotCrash() throws {
        let app = launchWithProcessedPhotos()
        defer { app.terminate() }

        let preview = app.images["PhotoPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))

        // Double-click to toggle zoom
        preview.doubleClick()
        Thread.sleep(forTimeInterval: 1)

        // App should still be running — preview should still exist
        XCTAssertTrue(preview.exists,
                       "Preview should remain after double-click zoom toggle")

        // Double-click again to zoom back
        preview.doubleClick()
        Thread.sleep(forTimeInterval: 1)

        XCTAssertTrue(preview.exists,
                       "Preview should remain after second double-click zoom toggle")
    }
}
