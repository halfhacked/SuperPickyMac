import XCTest

/// BDD: Processing flow — user picks a folder and processes bird photos.
final class ProcessingFlowUITests: XCTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Scenario: Empty state shows Select Folder button

    func testEmptyStateShowsSelectFolder() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TEST_MODE"] = "1"
        app.launch()
        defer { app.terminate() }

        let selectButton = app.buttons["SelectFolderButton"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: 5), "Empty state should show Select Folder button")
    }

    // MARK: - Scenario: Sidebar shows ratings

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

    // MARK: - Scenario: Processing folder appears in sidebar

    func testProcessFolderAppearsInSidebar() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TEST_MODE"] = "1"
        app.launchEnvironment["TEST_FOLDER"] = createTestFolder()
        app.launch()
        defer { app.terminate() }

        let folderLabel = app.staticTexts["superpicky_uitest"]
        XCTAssertTrue(folderLabel.waitForExistence(timeout: 10), "Folder should appear in sidebar")
    }

    // MARK: - Scenario: Photos not moved (auto-organize off)

    func testPhotosNotMovedAfterProcessing() throws {
        let testDir = createTestFolder()
        let app = XCUIApplication()
        app.launchEnvironment["TEST_MODE"] = "1"
        app.launchEnvironment["TEST_FOLDER"] = testDir
        app.launch()
        defer { app.terminate() }

        let folderLabel = app.staticTexts["superpicky_uitest"]
        XCTAssertTrue(folderLabel.waitForExistence(timeout: 10))
        sleep(5)

        for i in 1...3 {
            let path = (testDir as NSString).appendingPathComponent("bird\(i).jpg")
            XCTAssertTrue(FileManager.default.fileExists(atPath: path),
                "bird\(i).jpg should stay in root")
        }
    }

    // MARK: - Scenario: Database created after processing

    func testDatabaseCreatedAfterProcessing() throws {
        let testDir = createTestFolder()
        let app = XCUIApplication()
        app.launchEnvironment["TEST_MODE"] = "1"
        app.launchEnvironment["TEST_FOLDER"] = testDir
        app.launch()
        defer { app.terminate() }

        let folderLabel = app.staticTexts["superpicky_uitest"]
        XCTAssertTrue(folderLabel.waitForExistence(timeout: 10))
        sleep(5)

        let dbPath = (testDir as NSString).appendingPathComponent(".report.db")
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath), "Database should be created")
    }

    // MARK: - Helpers

    private func createTestFolder() -> String {
        let dir = NSTemporaryDirectory() + "superpicky_uitest"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        for i in 1...3 {
            let path = (dir as NSString).appendingPathComponent("bird\(i).jpg")
            createMinimalJPEG(at: path)
        }
        return dir
    }

    private func createMinimalJPEG(at path: String) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil, width: 100, height: 100,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        ), let image = context.makeImage() else { return }

        let url = URL(fileURLWithPath: path)
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else { return }
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }
}
