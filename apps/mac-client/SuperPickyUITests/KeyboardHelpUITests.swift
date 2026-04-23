import XCTest

/// XCUITests for the Keyboard Shortcuts help overlay (? key).
final class KeyboardHelpUITests: XCTestCase {

    static var app: XCUIApplication!
    static var testDir: String!

    override class func setUp() {
        super.setUp()

        testDir = NSTemporaryDirectory() + "superpicky_kbdhelp_\(UUID().uuidString.prefix(8))"
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
        // PhotoPreview enters the a11y tree only after the auto-selected
        // photo's full-res decode completes — CI lags on the ~3 MB fixture JPGs.
        _ = app.images["PhotoPreview"].waitForExistence(timeout: 15)
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

    func test01_QuestionMarkOpensHelp() {
        let app = Self.app!
        let preview = app.images["PhotoPreview"]
        XCTAssertTrue(preview.waitForExistence(timeout: 10))
        preview.click()
        Thread.sleep(forTimeInterval: 0.3)

        // ? is Shift+/ — XCUIApplication.typeText sends the literal char
        // which is how ContentView.handleKey dispatches ("?" case).
        app.typeText("?")
        Thread.sleep(forTimeInterval: 0.4)

        let overlay = app.descendants(matching: .any)["KeyboardHelpOverlay"]
        XCTAssertTrue(overlay.waitForExistence(timeout: 2),
                      "? should open the keyboard help overlay")
    }

    func test02_AnyKeyDismissesHelp() {
        let app = Self.app!
        let overlay = app.descendants(matching: .any)["KeyboardHelpOverlay"]
        if !overlay.exists {
            // Re-open from clean state
            app.images["PhotoPreview"].click()
            Thread.sleep(forTimeInterval: 0.2)
            app.typeText("?")
            _ = overlay.waitForExistence(timeout: 2)
        }
        XCTAssertTrue(overlay.exists, "Overlay should be present before dismissal")

        // handleKey dismisses on *any* key press when showKeyboardHelp is set.
        app.typeKey(.escape, modifierFlags: [])
        Thread.sleep(forTimeInterval: 0.4)
        XCTAssertFalse(overlay.exists, "Any key should dismiss the keyboard help overlay")
    }
}
