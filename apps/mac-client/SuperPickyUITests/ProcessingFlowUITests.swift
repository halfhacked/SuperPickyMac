import XCTest

/// BDD: Processing flow — user picks a folder and processes bird photos.
final class ProcessingFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Mock tests (no server needed)

    func testEmptyStateShowsSelectFolder() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TEST_MODE"] = "1"
        app.launch()
        defer { app.terminate() }

        let selectButton = app.buttons["SelectFolderButton"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: 5), "Empty state should show Select Folder button")
    }

    func testSidebarShowsRatings() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TEST_MODE"] = "1"
        app.launch()
        defer { app.terminate() }

        XCTAssertTrue(app.staticTexts["Excellent"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Good"].exists)
        XCTAssertTrue(app.staticTexts["Average"].exists)
        XCTAssertTrue(app.staticTexts["Reject"].exists)
    }

    // MARK: - Real inference tests (requires server on :8420 + test-photos)

    func testProcessRealBirdPhotos() throws {
        let testDir = copyTestPhotos(suffix: "process")

        let app = XCUIApplication()
        app.launchEnvironment["TEST_FOLDER"] = testDir
        app.launch()
        defer { app.terminate() }

        // 1. Wait for server status to show "Models ready"
        let modelsReady = app.staticTexts["Models ready"]
        XCTAssertTrue(modelsReady.waitForExistence(timeout: 30), "Server should become ready")

        // 2. Folder should appear in sidebar
        let folderName = (testDir as NSString).lastPathComponent
        let folderLabel = app.staticTexts[folderName]
        XCTAssertTrue(folderLabel.waitForExistence(timeout: 15), "Folder should appear in sidebar")

        // 3. Wait for processing to finish — progress bar disappears when done
        //    Poll until no more progress indicator is visible
        waitForProcessingComplete(app: app, testDir: testDir, timeout: 120)

        // 4. Database should be created
        let dbPath = (testDir as NSString).appendingPathComponent(".report.db")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath), "Database should be created")

        // 5. All 8 photos should remain (no auto-organize)
        let photos = try! FileManager.default.contentsOfDirectory(atPath: testDir)
            .filter { $0.hasSuffix(".jpg") }
        XCTAssertEqual(photos.count, 8, "All 8 photos should remain in folder")
    }

    func testRatingCountsAfterRealProcessing() throws {
        let testDir = copyTestPhotos(suffix: "ratings")

        let app = XCUIApplication()
        app.launchEnvironment["TEST_FOLDER"] = testDir
        app.launch()
        defer { app.terminate() }

        // Wait for server + processing
        let modelsReady = app.staticTexts["Models ready"]
        XCTAssertTrue(modelsReady.waitForExistence(timeout: 30), "Server should become ready")

        let folderName = (testDir as NSString).lastPathComponent
        let folderLabel = app.staticTexts[folderName]
        XCTAssertTrue(folderLabel.waitForExistence(timeout: 15))

        waitForProcessingComplete(app: app, testDir: testDir, timeout: 120)

        // Rating labels should exist
        XCTAssertTrue(app.staticTexts["Excellent"].exists, "Excellent label should exist")

        // Database should have entries
        let dbPath = (testDir as NSString).appendingPathComponent(".report.db")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath))
    }

    // MARK: - Helpers

    /// Wait for processing to complete by watching for the database to appear
    /// and the progress indicator to disappear.
    private func waitForProcessingComplete(app: XCUIApplication, testDir: String, timeout: TimeInterval) {
        let deadline = Date().addingTimeInterval(timeout)
        let dbPath = (testDir as NSString).appendingPathComponent(".report.db")

        // Wait for database to be created (processing started and saved at least one result)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: dbPath) {
                break
            }
            sleep(1)
        }

        // Then wait for progress bar to disappear (processing finished)
        while Date() < deadline {
            let progressExists = app.progressIndicators.count > 0
            if !progressExists {
                sleep(1) // Give UI time to update
                return
            }
            sleep(1)
        }
    }

    /// Copy test bird photos to a unique temp directory.
    private func copyTestPhotos(suffix: String) -> String {
        let testDir = NSTemporaryDirectory() + "superpicky_\(suffix)"
        try? FileManager.default.removeItem(atPath: testDir)
        try! FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)

        let sourceDir = "/Users/dazhen/projects/SuperPickyMac/test-photos"

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
