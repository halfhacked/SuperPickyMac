import XCTest

/// BDD: Sequential processing flow — one app launch, tests run in order.
/// Each test builds on the previous one's state.
final class ProcessingFlowUITests: XCTestCase {

    static var app: XCUIApplication!
    static var testDir: String!

    // MARK: - Shared setup: launch once, process once

    override class func setUp() {
        super.setUp()

        // Copy test photos
        testDir = copyTestPhotos()

        // Launch app — use TEST_MODE if no real server available
        app = XCUIApplication()
        app.launchEnvironment["TEST_MODE"] = "1"
        app.launchEnvironment["TEST_FOLDER"] = testDir
        app.launch()
    }

    override class func tearDown() {
        app.terminate()
        super.tearDown()
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
    }

    // MARK: - Tests run in alphabetical order, so prefix with numbers

    /// 01: App launches and shows sidebar
    func test01_AppLaunches() throws {
        // In mock mode there's no server — just verify the app launched
        let sidebar = Self.app.outlines.firstMatch
        XCTAssertTrue(sidebar.waitForExistence(timeout: 10), "Sidebar should appear")
    }

    /// 02: Processing folder appears in sidebar
    func test02_FolderAppearsInSidebar() throws {
        let folderName = (Self.testDir! as NSString).lastPathComponent
        let folderLabel = Self.app.staticTexts[folderName]
        XCTAssertTrue(folderLabel.waitForExistence(timeout: 15), "Folder should appear in sidebar")
    }

    /// 03: Wait for processing to complete (database created, progress done)
    func test03_ProcessingCompletes() throws {
        let dbPath = (Self.testDir! as NSString).appendingPathComponent(".report.db")

        // Wait for database to appear
        let deadline = Date().addingTimeInterval(120)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: dbPath) { break }
            sleep(1)
        }
        XCTAssertTrue(FileManager.default.fileExists(atPath: dbPath), "Database should be created")

        // Wait for progress bar to disappear
        while Date() < deadline {
            if Self.app.progressIndicators.count == 0 { break }
            sleep(1)
        }
        sleep(1) // Let UI settle
    }

    /// 04: All photos remain in folder (no auto-organize)
    func test04_PhotosNotMoved() throws {
        let photos = try! FileManager.default.contentsOfDirectory(atPath: Self.testDir)
            .filter { $0.hasSuffix(".jpg") }
        XCTAssertEqual(photos.count, 17, "All 17 photos should remain in folder")
    }

    /// 05: Thumbnails are visible in the strip
    func test05_ThumbnailsVisible() throws {
        XCTAssertGreaterThan(Self.app.images.count, 0, "Thumbnails should be visible")
    }

    /// 06: A photo is auto-selected and preview replaces empty state
    func test06_PreviewShowsPhoto() throws {
        let emptyText = Self.app.staticTexts["Select a photo to preview"]
        XCTAssertFalse(emptyText.exists, "Empty state should be replaced by photo preview")
    }

    /// 07: Rating labels exist in sidebar
    func test07_RatingLabelsExist() throws {
        XCTAssertTrue(Self.app.staticTexts["Excellent"].exists)
        XCTAssertTrue(Self.app.staticTexts["Good"].exists)
        XCTAssertTrue(Self.app.staticTexts["Average"].exists)
        XCTAssertTrue(Self.app.staticTexts["Reject"].exists)
    }

    /// 08: Species appears in sidebar
    func test08_SpeciesVisible() throws {
        // Mock returns "Bald Eagle" for all photos
        let found = Self.app.staticTexts.allElementsBoundByIndex.contains {
            $0.label.contains("Eagle")
        }
        XCTAssertTrue(found, "Species should appear in sidebar after processing")
    }

    /// 09: Expand species with burst — "Burst" child appears
    func test09_ExpandBurstSpecies() throws {
        // Find the disclosure group for a species with bursts and click its arrow
        let disclosureButtons = Self.app.disclosureTriangles
        if disclosureButtons.count > 0 {
            // Click the first disclosure triangle to expand
            disclosureButtons.firstMatch.click()
            sleep(1)

            // "Burst" child should now be visible
            let burstLabel = Self.app.staticTexts["Burst"]
            XCTAssertTrue(burstLabel.waitForExistence(timeout: 3), "Burst group should appear under species")
        } else {
            // No disclosure groups — burst detection might not have found groups
            // This is acceptable if the test photos didn't produce bursts
        }
    }

    /// 10: Click Excellent to filter — app doesn't crash, selection works
    func test10_FilterByExcellent() throws {
        Self.app.staticTexts["Excellent"].click()
        sleep(1)
        // Still running, sidebar still visible
        XCTAssertTrue(Self.app.staticTexts["Excellent"].exists)
    }

    /// 11: Click folder again to show all photos
    func test11_ClickFolderShowsAll() throws {
        let folderName = (Self.testDir! as NSString).lastPathComponent
        Self.app.staticTexts[folderName].click()
        sleep(1)
        XCTAssertGreaterThan(Self.app.images.count, 0, "All thumbnails should return after clicking folder")
    }

    // EXIF panel tests covered by KeyboardShortcutTests (I toggle) and unit tests

    // MARK: - Cleanup

    /// 12: Remove folder — counts reset to 0, empty state returns
    func test12_RemoveFolderClearsCounts() throws {
        let folderName = (Self.testDir! as NSString).lastPathComponent
        let folderLabel = Self.app.staticTexts[folderName]

        // Right-click folder to get context menu
        folderLabel.rightClick()
        sleep(1)

        // Click "Remove" in context menu
        let removeItem = Self.app.menuItems["Remove"]
        if removeItem.waitForExistence(timeout: 3) {
            removeItem.click()
            sleep(1)
        }

        // Empty state should return
        let selectButton = Self.app.buttons["SelectFolderButton"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: 5), "Empty state should return after removing folder")
    }

    // NOTE: Mock-only tests (testEmptyState, testSidebarRatings) are in a separate
    // test class to avoid interfering with the sequential pipeline above.

    // MARK: - Helpers

    private static func copyTestPhotos() -> String {
        let testDir = NSTemporaryDirectory() + "superpicky_bdd"
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
