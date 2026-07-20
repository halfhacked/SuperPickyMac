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

    /// Fixture directory (relative to `SuperPickyUITests/`) to copy into
    /// `testDir` before launch. Override to use a smaller purpose-built
    /// fixture — e.g. species tests only need ~3 photos, so they don't
    /// have to pay the ~20s full-fixture processing cost.
    class var fixtureFolder: String { "test-photos" }

    override class func setUp() {
        super.setUp()
        testDir = makeTestDir(prefix: testDirPrefix)
        copyFixtures(from: fixtureFolder, to: testDir)
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

    private static func copyFixtures(from fixtureFolder: String, to testDir: String) {
        let sourceDir = fixturesRoot.appendingPathComponent(fixtureFolder).path
        guard FileManager.default.fileExists(atPath: sourceDir) else { return }
        let photos = try! FileManager.default.contentsOfDirectory(atPath: sourceDir)
            .filter { $0.hasSuffix(".jpg") || $0.hasSuffix(".xmp") }
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

    /// #filePath resolves to this source file, which sits at
    /// app/SuperPickyUITests/. Fixtures live alongside it.
    static var fixturesRoot: URL {
        URL(fileURLWithPath: #filePath).deletingLastPathComponent()
    }
}
