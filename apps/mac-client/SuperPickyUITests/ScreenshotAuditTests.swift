import XCTest

/// Screenshot audit: processes real-photos, captures screenshots at key moments for visual inspection.
/// Run with: xcodebuild test -scheme SuperPicky -destination 'platform=macOS' -only-testing:SuperPickyUITests/ScreenshotAuditTests
final class ScreenshotAuditTests: XCTestCase {

    static var app: XCUIApplication!
    static var testDir: String!

    override class func setUp() {
        super.setUp()

        testDir = "/Users/dazhen/projects/SuperPickyMac/real-photos"

        // Clean DB for fresh run
        try? FileManager.default.removeItem(atPath: testDir + "/.report.db")

        app = XCUIApplication()
        app.launchEnvironment["TEST_FOLDER"] = testDir
        app.launch()
    }

    override class func tearDown() {
        app.terminate()
        super.tearDown()
    }

    override func setUpWithError() throws {
        continueAfterFailure = true
    }

    private func screenshot(_ name: String) {
        let shot = XCUIScreen.main.screenshot()
        let attachment = XCTAttachment(screenshot: shot)
        attachment.name = name
        attachment.lifetime = .keepAlways
        add(attachment)
    }

    // MARK: - Tests

    func test01_WaitForProcessingAndScreenshot() {
        // Wait for server + processing to start
        let modelsReady = Self.app.staticTexts["Models ready"]
        XCTAssertTrue(modelsReady.waitForExistence(timeout: 30), "Server should become ready")
        screenshot("01_server_ready")

        // Wait for some photos to process
        sleep(15)
        screenshot("02_processing_in_progress")

        // Wait for processing to complete
        let dbPath = Self.testDir! + "/.report.db"
        let deadline = Date().addingTimeInterval(180)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: dbPath) {
                // Check if all photos processed
                let count = try? self.photoCount(dbPath: dbPath)
                if count ?? 0 >= 100 { break }
            }
            sleep(5)
        }
        sleep(3) // Let UI settle
        screenshot("03_processing_complete")
    }

    func test02_MainViewScreenshots() {
        // Take screenshot of main view with thumbnails
        sleep(2)
        screenshot("04_main_view_thumbnails")

        // Click a few thumbnails and capture
        let images = Self.app.images.allElementsBoundByIndex
        if images.count >= 2 {
            images[1].click()
            sleep(1)
            screenshot("05_photo_selected")
        }
    }

    func test03_ExifPanelScreenshots() {
        // Open EXIF panel
        let toggle = Self.app.buttons["ExifToggle"]
        if toggle.waitForExistence(timeout: 5) {
            toggle.click()
            sleep(1)
            screenshot("06_exif_panel_open")
        }

        // Click different photos to see EXIF change
        let images = Self.app.images.allElementsBoundByIndex
        if images.count >= 5 {
            images[4].click()
            sleep(1)
            screenshot("07_exif_different_photo")
        }
    }

    func test04_SidebarScreenshots() {
        // Screenshot sidebar with ratings and species
        screenshot("08_sidebar_ratings_species")

        // Click Excellent filter
        if Self.app.staticTexts["Excellent"].exists {
            Self.app.staticTexts["Excellent"].click()
            sleep(1)
            screenshot("09_filtered_excellent")
        }

        // Click back to folder
        let folderName = (Self.testDir! as NSString).lastPathComponent
        if Self.app.staticTexts[folderName].exists {
            Self.app.staticTexts[folderName].click()
            sleep(1)
        }
    }

    func test05_SpeciesFilter() {
        // Find and click a species in sidebar
        let speciesFound = Self.app.staticTexts.allElementsBoundByIndex.first {
            let label = $0.label
            return label.contains("Loon") || label.contains("Eagle") ||
                   label.contains("Goldeneye") || label.contains("Guillemot")
        }
        if let species = speciesFound {
            species.click()
            sleep(1)
            screenshot("10_species_filtered")
        }
    }

    func test06_ScrollThumbnails() {
        // Go back to all photos
        let folderName = (Self.testDir! as NSString).lastPathComponent
        if Self.app.staticTexts[folderName].exists {
            Self.app.staticTexts[folderName].click()
            sleep(1)
        }

        // Scroll to end of thumbnail strip
        let images = Self.app.images.allElementsBoundByIndex
        if let last = images.last {
            last.click()
            sleep(1)
            screenshot("11_last_photo")
        }
    }

    // MARK: - Helpers

    private func photoCount(dbPath: String) throws -> Int {
        // Quick count via sqlite3 command
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sqlite3")
        process.arguments = [dbPath, "SELECT COUNT(*) FROM photos;"]
        let pipe = Pipe()
        process.standardOutput = pipe
        try process.run()
        process.waitUntilExit()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        return Int(String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "0") ?? 0
    }
}
