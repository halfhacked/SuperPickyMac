import XCTest

/// Consolidated XCUITests for culling workflow features.
/// Uses a single shared app instance with processed test photos to minimize launch overhead.
/// Tests are numbered to run sequentially, each building on the shared state.
///
/// Categories:
/// - 01-09: UI elements (sidebar, info bar, toolbar)
/// - 10-19: Keyboard shortcuts (fullscreen, zoom, navigation)
/// - 20-29: Star filter and photo counter
/// - 30-39: Export
final class CullingWorkflowUITests: XCTestCase {

    static var app: XCUIApplication!
    static var testDir: String!

    override class func setUp() {
        super.setUp()

        testDir = NSTemporaryDirectory() + "superpicky_workflow_\(UUID().uuidString.prefix(8))"
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

        app = XCUIApplication()
        app.launchEnvironment["TEST_MODE"] = "1"
        app.launchEnvironment["TEST_FOLDER"] = testDir
        app.launch()

        // Wait for processing to complete
        _ = app.images.firstMatch.waitForExistence(timeout: 15)
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline {
            if app.progressIndicators.count == 0 { break }
            Thread.sleep(forTimeInterval: 0.5)
        }
        Thread.sleep(forTimeInterval: 1)
    }

    override class func tearDown() {
        app.terminate()
        try? FileManager.default.removeItem(atPath: testDir)
        super.tearDown()
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    // MARK: - 01-09: UI Elements

    func test01_SidebarRatingLabels() {
        let app = Self.app!
        XCTAssertTrue(app.staticTexts["Excellent"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["Good"].exists)
        XCTAssertTrue(app.staticTexts["Average"].exists)
        XCTAssertTrue(app.staticTexts["Below Average"].exists)
        XCTAssertTrue(app.staticTexts["Poor"].exists)
        XCTAssertTrue(app.staticTexts["Reject"].exists)

        // Verify descending order
        let excellent = app.staticTexts["Excellent"]
        let reject = app.staticTexts["Reject"]
        XCTAssertLessThan(excellent.frame.minY, reject.frame.minY)
    }

    func test02_PreviewAndInfoBar() {
        let app = Self.app!
        let preview = app.images["PhotoPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10),
                      "Photo preview should be visible")

        let infoBar = app.descendants(matching: .any)["InfoBar"]
        XCTAssertTrue(infoBar.waitForExistence(timeout: 5),
                      "InfoBar should be visible")

        // No manual rating pencil for AI-rated photos
        XCTAssertFalse(app.images["ManualRatingIndicator"].exists,
                       "Pencil should not appear for AI-rated photos")
    }

    func test03_ExportPicksButtonExists() {
        let app = Self.app!
        let exportButton = app.buttons["ExportPicksButton"]
        XCTAssertTrue(exportButton.waitForExistence(timeout: 10),
                      "Export Picks button should exist in toolbar")
        XCTAssertTrue(exportButton.isEnabled)
    }

    func test04_ExifToggle() {
        let app = Self.app!
        let toggle = app.buttons["ExifToggle"]
        XCTAssertTrue(toggle.waitForExistence(timeout: 5),
                      "EXIF toggle button should exist")
    }

    // MARK: - 10-19: Keyboard Shortcuts

    func test10_FullscreenToggle() {
        let app = Self.app!
        let preview = app.images["PhotoPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))

        // F enters fullscreen
        preview.click()
        app.typeKey("f", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        let fullscreen = app.otherElements["FullscreenViewer"]
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 3),
                      "Fullscreen should open with F")

        // Escape exits fullscreen
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertFalse(fullscreen.exists,
                       "Escape should close fullscreen")
    }

    func test11_FullscreenArrowNavigation() {
        let app = Self.app!
        let preview = app.images["PhotoPreview"]
        preview.click()

        app.typeKey("f", modifierFlags: [])
        let fullscreen = app.otherElements["FullscreenViewer"]
        XCTAssertTrue(fullscreen.waitForExistence(timeout: 3))

        // Arrow keys navigate without crash
        app.typeKey(.rightArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.leftArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        XCTAssertTrue(fullscreen.exists, "Fullscreen should remain open after navigation")

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
    }

    func test12_ZoomDoesNotCrash() {
        let app = Self.app!
        let preview = app.images["PhotoPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))

        // Double-click zoom toggle
        preview.doubleClick()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(preview.exists)

        preview.doubleClick()
        Thread.sleep(forTimeInterval: 1)
        XCTAssertTrue(preview.exists)
    }

    func test13_ArrowKeyNavigation() {
        let app = Self.app!
        let preview = app.images["PhotoPreview"]
        preview.click()
        Thread.sleep(forTimeInterval: 0.5)

        app.typeKey(.rightArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey(.leftArrow, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(preview.exists, "Preview should remain after arrow navigation")
    }

    func test14_FullscreenZoom() {
        let app = Self.app!
        let preview = app.images["PhotoPreview"]
        preview.click()

        // Enter fullscreen, toggle zoom, exit
        app.typeKey("f", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        app.typeKey("z", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)
        app.typeKey("z", modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.5)

        XCTAssertTrue(preview.exists, "Preview should remain after fullscreen zoom")
    }

    // MARK: - 20-29: Star Filter

    func test20_StarFilterBarVisible() {
        let app = Self.app!
        let filter = app.descendants(matching: .any)["StarFilter"]
        XCTAssertTrue(filter.waitForExistence(timeout: 5),
                      "Star filter control should be visible")
    }

    func test21_PhotoCounterVisible() {
        let app = Self.app!
        let counter = app.staticTexts["PhotoCounter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 5),
                      "Photo counter should be visible")
    }

    func test22_StarFilterAndReset() {
        let app = Self.app!
        let counter = app.staticTexts["PhotoCounter"]
        XCTAssertTrue(counter.waitForExistence(timeout: 3))
        let initialText = counter.value as? String ?? ""
        XCTAssertTrue(initialText.contains(" of "),
                      "Counter should show 'N of M' format, got: \(initialText)")

        // Set filter to ≥ 5
        let preview = app.images["PhotoPreview"]
        preview.click()
        app.typeKey("5", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1)

        let filteredText = counter.value as? String ?? ""
        XCTAssertTrue(filteredText.contains(" of "),
                      "Counter should show 'N of M' after filter, got: \(filteredText)")

        // Reset to all
        app.typeKey("0", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1)

        let resetText = counter.value as? String ?? ""
        XCTAssertEqual(resetText, initialText,
                       "After reset, counter should match initial")
    }
}
