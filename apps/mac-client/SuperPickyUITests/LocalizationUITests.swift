import XCTest

/// Tests that switching language to Chinese localizes the UI.
/// Shares one app instance with processed photos.
final class LocalizationUITests: XCTestCase {

    static var app: XCUIApplication!
    static var testDir: String!

    override class func setUp() {
        super.setUp()

        testDir = NSTemporaryDirectory() + "superpicky_l10n_\(UUID().uuidString.prefix(8))"
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

    // MARK: - Tests

    func test01_SwitchToChinese() {
        let app = Self.app!

        // Open Settings
        app.typeKey(",", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1)

        // Find the Language picker and switch to Chinese
        let settingsWindow = app.windows.element(boundBy: 1).exists ? app.windows.element(boundBy: 1) : app.windows.firstMatch

        // Click the Language popup button
        let langPopup = settingsWindow.popUpButtons.firstMatch
        if langPopup.waitForExistence(timeout: 5) {
            langPopup.click()
            Thread.sleep(forTimeInterval: 0.5)

            // Select Chinese option
            let zhOption = app.menuItems["中文（简体）"]
            if zhOption.waitForExistence(timeout: 3) {
                zhOption.click()
                Thread.sleep(forTimeInterval: 2)
            }
        }

        // Close settings
        app.typeKey("w", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1)
    }

    func test02_SidebarLabelsLocalized() {
        let app = Self.app!

        // Sidebar rating labels should be in Chinese
        XCTAssertTrue(app.staticTexts["优秀"].waitForExistence(timeout: 5),
                      "Rating '优秀' (Excellent) should appear in Chinese")
        XCTAssertTrue(app.staticTexts["良好"].exists, "Rating '良好' (Good) should appear")
        XCTAssertTrue(app.staticTexts["淘汰"].exists, "Rating '淘汰' (Reject) should appear")
    }

    func test03_SidebarSectionsLocalized() {
        let app = Self.app!

        XCTAssertTrue(app.staticTexts["评分"].waitForExistence(timeout: 5),
                      "Section '评分' (Ratings) should appear")
        XCTAssertTrue(app.staticTexts["标签"].exists, "Section '标签' (Tags) should appear")
        XCTAssertTrue(app.staticTexts["鸟种"].exists, "Section '鸟种' (Species) should appear")
    }

    func test04_SpeciesInChinese() {
        let app = Self.app!

        // Bald Eagle should show as 白头海雕
        XCTAssertTrue(app.staticTexts["白头海雕"].waitForExistence(timeout: 5),
                      "Bald Eagle should show as '白头海雕' in Chinese")
    }

    func test05_InfoBarLocalized() {
        let app = Self.app!

        let preview = app.images["PhotoPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))

        // Click on a photo with species to see info bar
        preview.click()
        Thread.sleep(forTimeInterval: 1)

        // Check info bar has Chinese labels - look for 锐度 (Sharpness) or 美学 (Aesthetics)
        let infoBar = app.otherElements["InfoBar"]
        XCTAssertTrue(infoBar.waitForExistence(timeout: 5))

        // The info bar text should contain Chinese characters
        let allTexts = app.staticTexts.allElementsBoundByIndex.map { $0.label }
        let hasChineseSharpness = allTexts.contains { $0.contains("锐度") }
        let hasChineseAesthetics = allTexts.contains { $0.contains("美学") }
        XCTAssertTrue(hasChineseSharpness || hasChineseAesthetics,
                      "Info bar should show '锐度' or '美学' in Chinese. Found: \(allTexts.filter { !$0.isEmpty }.joined(separator: ", "))")
    }

    func test06_SwitchBackToEnglish() {
        let app = Self.app!

        // Open Settings
        app.typeKey(",", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1)

        let langPopup = app.windows.element(boundBy: 1).exists
            ? app.windows.element(boundBy: 1).popUpButtons.firstMatch
            : app.popUpButtons.firstMatch

        if langPopup.waitForExistence(timeout: 5) {
            langPopup.click()
            Thread.sleep(forTimeInterval: 0.5)

            let enOption = app.menuItems["English"]
            if enOption.waitForExistence(timeout: 3) {
                enOption.click()
                Thread.sleep(forTimeInterval: 2)
            }
        }

        app.typeKey("w", modifierFlags: .command)
        Thread.sleep(forTimeInterval: 1)

        // Should be back to English
        XCTAssertTrue(app.staticTexts["Excellent"].waitForExistence(timeout: 5),
                      "Rating 'Excellent' should reappear after switching to English")
        XCTAssertTrue(app.staticTexts["Bald Eagle"].waitForExistence(timeout: 5),
                      "Species 'Bald Eagle' should reappear after switching to English")
    }
}
