import XCTest

/// Verifies that switching language in settings updates the menu bar.
/// Part of CullingWorkflowUITests in production — separate here for debugging.
final class MenuLocalizationTest: XCTestCase {

    static var app: XCUIApplication!
    static var testDir: String!

    override class func setUp() {
        super.setUp()
        testDir = NSTemporaryDirectory() + "sp_menu_\(UUID().uuidString.prefix(8))"
        try? FileManager.default.removeItem(atPath: testDir)
        try! FileManager.default.createDirectory(atPath: testDir, withIntermediateDirectories: true)

        let thisFile = URL(fileURLWithPath: #filePath)
        let projectRoot = thisFile.deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let sourceDir = projectRoot.appendingPathComponent("test-photos").path
        if FileManager.default.fileExists(atPath: sourceDir) {
            for photo in try! FileManager.default.contentsOfDirectory(atPath: sourceDir).filter({ $0.hasSuffix(".jpg") }) {
                try! FileManager.default.copyItem(
                    atPath: (sourceDir as NSString).appendingPathComponent(photo),
                    toPath: (testDir as NSString).appendingPathComponent(photo))
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

    func test01_SwitchToChineseUpdatesMenuBar() {
        let app = Self.app!

        // Open Settings
        app.typeKey(",", modifierFlags: .command)
        sleep(1)

        // Switch to Chinese
        let popup = app.popUpButtons.firstMatch
        XCTAssertTrue(popup.waitForExistence(timeout: 5), "Language popup should exist")
        popup.click()
        Thread.sleep(forTimeInterval: 0.5)
        let zhOption = app.menuItems["中文（简体）"]
        XCTAssertTrue(zhOption.waitForExistence(timeout: 3))
        zhOption.click()
        sleep(2)

        // Verify onChange fired via debug file
        let debug = try? String(contentsOfFile: "/tmp/sp_menu_debug.txt", encoding: .utf8)
        XCTAssertNotNil(debug, "onChange should have fired and written debug file")
        XCTAssertTrue(debug?.contains("zh-Hans") ?? false, "Debug should show zh-Hans, got: \(debug ?? "")")

        // Check menu bar has Chinese titles
        let menuBar = app.menuBars.firstMatch
        var titles: [String] = []
        for i in 0..<menuBar.menuBarItems.count {
            titles.append(menuBar.menuBarItems.element(boundBy: i).title)
        }

        XCTAssertTrue(titles.contains("文件") || !titles.contains("File"),
                      "Menu should show '文件' or at least not 'File'. Got: \(titles)")

        // Close settings
        app.typeKey("w", modifierFlags: .command)
        sleep(1)
    }
}
