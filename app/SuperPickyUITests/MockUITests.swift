import XCTest

/// Tests for empty/initial app state (no test folder, no photos).
/// Separate from CullingWorkflowUITests because it needs a different app launch config.
final class MockUITests: XCTestCase {

    func testEmptyStateShowsSelectFolder() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TEST_MODE"] = "1"
        app.launchArguments += ["-lastFolderPath", ""]
        app.launch()
        defer { app.terminate() }

        let selectButton = app.buttons["SelectFolderButton"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: 5))

        // Sidebar still shows rating labels even without photos
        XCTAssertTrue(app.staticTexts["Excellent"].waitForExistence(timeout: 5))
        XCTAssertTrue(app.staticTexts["0 Stars"].exists)
        XCTAssertTrue(app.staticTexts["Rejected"].exists)
    }
}
