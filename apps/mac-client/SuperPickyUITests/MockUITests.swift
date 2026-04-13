import XCTest

/// Mock tests that don't need the inference server.
final class MockUITests: XCTestCase {

    func testEmptyStateShowsSelectFolder() throws {
        let app = XCUIApplication()
        app.launchEnvironment["TEST_MODE"] = "1"
        app.launch()
        defer { app.terminate() }

        let selectButton = app.buttons["SelectFolderButton"]
        XCTAssertTrue(selectButton.waitForExistence(timeout: 5))
    }

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
}
