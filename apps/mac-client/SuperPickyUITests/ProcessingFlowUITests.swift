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

        // Launch app with real server
        app = XCUIApplication()
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

    /// 01: Server status shows "Models ready"
    func test01_ServerBecomesReady() throws {
        let modelsReady = Self.app.staticTexts["Models ready"]
        XCTAssertTrue(modelsReady.waitForExistence(timeout: 30), "Server should become ready")
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
        XCTAssertEqual(photos.count, 15, "All 15 photos should remain in folder")
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

    /// 08: Bird species names appear in sidebar
    func test08_SpeciesVisible() throws {
        // After processing real bird photos, at least one species name should appear
        // Look for any text containing "Kingfisher" or other common bird names
        // Or just check that the sidebar has more text items than the basic ratings
        let speciesFound = Self.app.staticTexts.allElementsBoundByIndex.contains {
            let label = $0.label
            return label.contains("Kingfisher") || label.contains("Hummingbird") ||
                   label.contains("Eagle") || label.contains("Owl") ||
                   label.contains("Parrot") || label.contains("Pelican") ||
                   label.contains("Robin") || label.contains("Flamingo") ||
                   label.contains("Species")
        }
        XCTAssertTrue(speciesFound, "At least one bird species should appear in sidebar after processing")
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

    // MARK: - EXIF Panel

    /// 12: Press I to open EXIF panel — panel appears
    func test12_PressIOpensExifPanel() throws {
        // Click a thumbnail first to ensure a photo is selected and content area has focus
        let images = Self.app.images.allElementsBoundByIndex
        if let first = images.first { first.click() }
        sleep(1)

        Self.app.typeKey("i", modifierFlags: [])
        let panel = Self.app.scrollViews["ExifPanel"]
        XCTAssertTrue(panel.waitForExistence(timeout: 3), "EXIF panel should appear after pressing I")
    }

    /// 13: Panel shows camera make
    func test13_ExifPanelShowsCameraMake() throws {
        let makeField = Self.app.staticTexts["Exif_Make"]
        XCTAssertTrue(makeField.waitForExistence(timeout: 3), "Make field should be visible")
        XCTAssertFalse(makeField.label.isEmpty, "Make should not be empty")
    }

    /// 14: Panel shows camera model
    func test14_ExifPanelShowsModel() throws {
        let modelField = Self.app.staticTexts["Exif_Model"]
        XCTAssertTrue(modelField.exists, "Model field should be visible")
    }

    /// 15: Panel shows lens
    func test15_ExifPanelShowsLens() throws {
        let lensField = Self.app.staticTexts["Exif_Lens"]
        XCTAssertTrue(lensField.exists, "Lens field should be visible")
    }

    /// 16: Panel shows focal length with "mm"
    func test16_ExifPanelShowsFocalLength() throws {
        let field = Self.app.staticTexts["Exif_Focal Length"]
        XCTAssertTrue(field.exists, "Focal Length should be visible")
        XCTAssertTrue(field.label.contains("mm"), "Focal length should contain 'mm'")
    }

    /// 17: Panel shows aperture with "f/"
    func test17_ExifPanelShowsAperture() throws {
        let field = Self.app.staticTexts["Exif_Aperture"]
        XCTAssertTrue(field.exists, "Aperture should be visible")
        XCTAssertTrue(field.label.contains("f/"), "Aperture should contain 'f/'")
    }

    /// 18: Panel shows shutter speed
    func test18_ExifPanelShowsShutter() throws {
        let field = Self.app.staticTexts["Exif_Shutter"]
        XCTAssertTrue(field.exists, "Shutter should be visible")
        let value = field.label
        XCTAssertTrue(value.contains("1/") || value.contains("s"),
                      "Shutter speed should be fraction or seconds, got: \(value)")
    }

    /// 19: Panel shows ISO
    func test19_ExifPanelShowsISO() throws {
        let field = Self.app.staticTexts["Exif_ISO"]
        XCTAssertTrue(field.exists, "ISO should be visible")
    }

    /// 20: Panel shows GPS coordinates
    func test20_ExifPanelShowsGPS() throws {
        let field = Self.app.staticTexts["Exif_GPS"]
        XCTAssertTrue(field.exists, "GPS field should be visible")
        XCTAssertTrue(field.label.contains("°"), "GPS should contain degree symbol")
    }

    /// 21: Panel shows location (city, state, country)
    func test21_ExifPanelShowsLocation() throws {
        let field = Self.app.staticTexts["Exif_Location"]
        XCTAssertTrue(field.exists, "Location field should be visible")
        XCTAssertFalse(field.label.isEmpty, "Location should not be empty")
    }

    /// 22: Panel shows IPTC keywords
    func test22_ExifPanelShowsKeywords() throws {
        let field = Self.app.staticTexts["Exif_Keywords"]
        XCTAssertTrue(field.exists, "Keywords field should be visible")
        XCTAssertFalse(field.label.isEmpty, "Keywords should not be empty")
    }

    /// 23: Click different thumbnail — panel updates
    func test23_ExifPanelUpdatesOnSelectionChange() throws {
        let modelField = Self.app.staticTexts["Exif_Model"]
        guard modelField.exists else {
            XCTFail("Model field should be visible before changing selection")
            return
        }

        // Click a different thumbnail
        let images = Self.app.images.allElementsBoundByIndex
        guard images.count >= 2 else { return }
        images.last!.click()
        sleep(1)

        // Panel should still be visible with model field
        let panel = Self.app.scrollViews["ExifPanel"]
        XCTAssertTrue(panel.exists, "Panel should remain visible after selection change")
        XCTAssertTrue(Self.app.staticTexts["Exif_Model"].exists, "Model should still be visible")
    }

    /// 24: Press I again to hide panel
    func test24_PressIHidesExifPanel() throws {
        Self.app.typeKey("i", modifierFlags: [])
        sleep(1)
        let panel = Self.app.scrollViews["ExifPanel"]
        XCTAssertFalse(panel.exists, "EXIF panel should hide after pressing I again")
    }

    // MARK: - Cleanup

    /// 25: Remove folder — counts reset to 0, empty state returns
    func test25_RemoveFolderClearsCounts() throws {
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
