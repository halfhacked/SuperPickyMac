import XCTest

/// Shared-app-instance base class: copies the JPG fixtures into a fresh
/// temp dir, launches SuperPicky in mock mode pointed at that dir, and
/// waits until the app has finished processing before the first test
/// runs. Subclasses override `testDirPrefix` to disambiguate the temp
/// folder (useful when debugging parallel runs).
class SuperPickyUITestCase: XCTestCase {

    static var app: XCUIApplication!
    static var testDir: String!

    /// Prefix for the per-suite temp directory. Override in subclasses.
    class var testDirPrefix: String { "superpicky" }

    override class func setUp() {
        super.setUp()
        testDir = makeTestDir(prefix: testDirPrefix)
        copyFixtures(to: testDir)
        app = launchApp(testFolder: testDir)
        app.waitUntilProcessed()
    }

    override class func tearDown() {
        app.terminate()
        try? FileManager.default.removeItem(atPath: testDir)
        super.tearDown()
    }

    // MARK: - Helpers

    private static func makeTestDir(prefix: String) -> String {
        let dir = NSTemporaryDirectory() + "\(prefix)_\(UUID().uuidString.prefix(8))"
        try? FileManager.default.removeItem(atPath: dir)
        try! FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
        return dir
    }

    private static func copyFixtures(to testDir: String) {
        let sourceDir = projectRoot.appendingPathComponent("test-photos").path
        guard FileManager.default.fileExists(atPath: sourceDir) else { return }
        let photos = try! FileManager.default.contentsOfDirectory(atPath: sourceDir)
            .filter { $0.hasSuffix(".jpg") }
        for photo in photos {
            try! FileManager.default.copyItem(
                atPath: (sourceDir as NSString).appendingPathComponent(photo),
                toPath: (testDir as NSString).appendingPathComponent(photo)
            )
        }
    }

    private static func launchApp(testFolder: String) -> XCUIApplication {
        let app = XCUIApplication()
        app.launchEnvironment["TEST_MODE"] = "1"
        app.launchEnvironment["TEST_FOLDER"] = testFolder
        app.launch()
        return app
    }

    /// #filePath resolves to this source file's on-disk location, which
    /// sits at apps/mac-client/SuperPickyUITests/ — four levels below the
    /// project root.
    private static var projectRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
