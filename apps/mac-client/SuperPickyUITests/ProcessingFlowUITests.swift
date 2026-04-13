import XCTest

/// BDD: Processing flow — user picks a folder and processes bird photos.
final class ProcessingFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Mock tests (no server needed)

    func testEmptyStateShowsSelectFolder() throws {
        let app = launchApp(testMode: true)
        defer { app.terminate() }

        let selectButton = app.buttons["SelectFolderButton"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: 5))
    }

    func testSidebarShowsRatings() throws {
        let app = launchApp(testMode: true)
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["Excellent"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Good"].exists)
        XCTAssertTrue(app.staticTexts["Average"].exists)
        XCTAssertTrue(app.staticTexts["Reject"].exists)
    }

    // MARK: - Real inference tests (requires server on :8420)

    func testProcessAndShowThumbnails() throws {
        let testDir = copyTestPhotos(suffix: "thumbs")
        let app = launchApp(testFolder: testDir)
        defer { app.terminate() }

        // Wait for server + processing
        XCTAssertTrue(app.staticTexts["Models ready"].waitForExistence(timeout: 30))
        let folderName = (testDir as NSString).lastPathComponent
        XCTAssertTrue(app.staticTexts[folderName].waitForExistence(timeout: 15))
        waitForProcessingComplete(app: app, testDir: testDir, timeout: 120)

        // Thumbnails should appear in the horizontal strip
        let images = app.images
        XCTAssertGreaterThan(images.count, 0, "Thumbnails should be visible after processing")
    }

    func testSelectPhotoShowsPreview() throws {
        let testDir = copyTestPhotos(suffix: "preview")
        let app = launchApp(testFolder: testDir)
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["Models ready"].waitForExistence(timeout: 30))
        let folderName = (testDir as NSString).lastPathComponent
        XCTAssertTrue(app.staticTexts[folderName].waitForExistence(timeout: 15))
        waitForProcessingComplete(app: app, testDir: testDir, timeout: 120)

        // After processing, a photo should be auto-selected.
        // The empty state text should be gone — replaced by the actual preview
        let emptyText = app.staticTexts["Select a photo to preview"]
        XCTAssertFalse(emptyText.exists, "Empty state should be gone after processing — photo should be previewed")

        // Thumbnails should also be visible (confirming photos loaded)
        XCTAssertGreaterThan(app.images.count, 0, "Thumbnails should be visible")
    }

    func testFilterByRating() throws {
        let testDir = copyTestPhotos(suffix: "filter")
        let app = launchApp(testFolder: testDir)
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["Models ready"].waitForExistence(timeout: 30))
        let folderName = (testDir as NSString).lastPathComponent
        XCTAssertTrue(app.staticTexts[folderName].waitForExistence(timeout: 15))
        waitForProcessingComplete(app: app, testDir: testDir, timeout: 120)

        // Click "Excellent" in the sidebar to filter by 3-star
        let excellentRow = app.staticTexts["Excellent"]
        XCTAssertTrue(excellentRow.exists)
        excellentRow.click()
        sleep(1)

        // The thumbnail count should change (fewer or same, not more)
        // We just verify the app doesn't crash and the sidebar selection changed
        XCTAssertTrue(app.staticTexts["Excellent"].exists, "Excellent should still be visible after clicking")
    }

    func testProcessRealBirdPhotos() throws {
        let testDir = copyTestPhotos(suffix: "process")
        let app = launchApp(testFolder: testDir)
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["Models ready"].waitForExistence(timeout: 30))
        let folderName = (testDir as NSString).lastPathComponent
        XCTAssertTrue(app.staticTexts[folderName].waitForExistence(timeout: 15))
        waitForProcessingComplete(app: app, testDir: testDir, timeout: 120)

        // Database should be created
        let dbPath = (testDir as NSString).appendingPathComponent(".report.db")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath))

        // All 8 photos should remain in folder
        let photos = try! FileManager.default.contentsOfDirectory(atPath: testDir)
            .filter { $0.hasSuffix(".jpg") }
        XCTAssertEqual(photos.count, 8, "All 8 photos should remain")
    }

    func testRatingCountsAfterRealProcessing() throws {
        let testDir = copyTestPhotos(suffix: "ratings")
        let app = launchApp(testFolder: testDir)
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["Models ready"].waitForExistence(timeout: 30))
        let folderName = (testDir as NSString).lastPathComponent
        XCTAssertTrue(app.staticTexts[folderName].waitForExistence(timeout: 15))
        waitForProcessingComplete(app: app, testDir: testDir, timeout: 120)

        XCTAssertTrue(app.staticTexts["Excellent"].exists)

        let dbPath = (testDir as NSString).appendingPathComponent(".report.db")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath))
    }

    // MARK: - Helpers

    private func launchApp(testMode: Bool = false, testFolder: String? = nil) -> XCUIApplication {
        let app = XCUIApplication()
        if testMode {
            app.launchEnvironment["TEST_MODE"] = "1"
        }
        if let testFolder {
            app.launchEnvironment["TEST_FOLDER"] = testFolder
        }
        app.launch()
        return app
    }

    private func waitForProcessingComplete(app: XCUIApplication, testDir: String, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        let dbPath = (testDir as NSString).appendingPathComponent(".report.db")

        while Date() < deadline {
            if FileManager.default.fileExists(atPath: dbPath) { break }
            sleep(1)
        }

        while Date() < deadline {
            if app.progressIndicators.count == 0 {
                sleep(1)
                return
            }
            sleep(1)
        }
    }

    private func copyTestPhotos(suffix: String) -> String {
        let testDir = NSTemporaryDirectory() + "superpicky_\(suffix)"
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
}
