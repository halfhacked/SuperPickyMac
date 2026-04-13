import XCTest

/// BDD: Processing flow — user picks a folder and processes bird photos.
final class ProcessingFlowUITests: XCTestCase {

    var app: XCUIApplication!

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        // Test mode: bypass Python server, use mock inference
        app.launchEnvironment["TEST_MODE"] = "1"
        app.launchEnvironment["TEST_FOLDER"] = createTestFolder()
        app.launch()
    }

    override func tearDownWithError() throws {
        app.terminate()
    }

    // MARK: - Scenario: Open processing sheet via toolbar button

    func testClickPlusOpensProcessingSheet() throws {
        let toolbar = app.toolbars
        let plusButton = toolbar.buttons["ProcessNewFolder"]
        XCTAssertTrue(plusButton.waitForExistence(timeout: 5), "Toolbar + button should exist")
        plusButton.click()

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Processing sheet should appear")
    }

    // MARK: - Scenario: Open processing sheet via Cmd+O

    func testCmdOOpensProcessingSheet() throws {
        app.typeKey("o", modifierFlags: .command)

        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5), "Cmd+O should open processing sheet")
    }

    // MARK: - Scenario: Sheet shows pre-filled folder from TEST_FOLDER

    func testSheetShowsPrefilledFolder() throws {
        // Sheet auto-opens because TEST_FOLDER is set
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))

        // Folder name should be visible
        let folderLabel = app.staticTexts["superpicky_uitest"]
        XCTAssertTrue(folderLabel.waitForExistence(timeout: 3), "Pre-filled folder name should be displayed")

        // Start Processing button should be visible (folder is selected)
        let startButton = sheet.buttons["Start Processing"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 3), "Start Processing button should appear when folder is set")
    }

    // MARK: - Scenario: Process folder and see completion

    func testProcessFolderToCompletion() throws {
        // Sheet auto-opens with TEST_FOLDER
        let sheet = app.sheets.firstMatch
        XCTAssertTrue(sheet.waitForExistence(timeout: 5))

        // Click Start Processing
        let startButton = sheet.buttons["Start Processing"]
        XCTAssertTrue(startButton.waitForExistence(timeout: 3))
        startButton.click()

        // Wait for "Processing complete!" text
        let completeText = app.staticTexts["Processing complete!"]
        XCTAssertTrue(completeText.waitForExistence(timeout: 30), "Processing should complete")

        // Click Done
        let doneButton = sheet.buttons["Done"]
        XCTAssertTrue(doneButton.waitForExistence(timeout: 5))
        doneButton.click()

        // Sheet should dismiss — verify sidebar shows the folder
        let folderInSidebar = app.staticTexts["superpicky_uitest"]
        XCTAssertTrue(folderInSidebar.waitForExistence(timeout: 5), "Processed folder should appear in sidebar")
    }

    // MARK: - Scenario: Settings opens with Cmd+,

    func testSettingsOpens() throws {
        // Close auto-opened sheet first
        app.typeKey(.escape, modifierFlags: [])
        sleep(1)

        app.typeKey(",", modifierFlags: .command)
        sleep(1)

        // SwiftUI Settings scene may use different window titles
        // Check that a new window appeared (app should have 2+ windows)
        let windowCount = app.windows.count
        XCTAssertGreaterThanOrEqual(windowCount, 2, "Settings should open a new window")
    }

    // MARK: - Helpers

    private func createTestFolder() -> String {
        let dir = NSTemporaryDirectory() + "superpicky_uitest"
        try? FileManager.default.removeItem(atPath: dir)
        try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)

        // Create minimal JPEG test files
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
