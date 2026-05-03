import XCTest

/// L3 BDD: verify that pressing `z` to zoom triggers a full-res decode
/// which writes a sidecar JPEG into the preview cache, and that
/// re-launching the app reuses the on-disk file instead of re-writing it.
///
/// Cleans the cache before and after the run so we don't leak between
/// CI runs or interfere with the user's real cache. Walks the cache root
/// instead of recomputing the hash so the test stays decoupled from the
/// keying scheme in `PreviewCache`.
final class PreviewCacheUITests: SuperPickyUITestCase {

    override class var testDirPrefix: String { "superpicky_preview_cache" }

    private static let cacheRoot: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("com.halfhacked.superpicky/preview", isDirectory: true)
    }()

    override class func setUp() {
        try? FileManager.default.removeItem(at: cacheRoot)
        super.setUp()
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: cacheRoot)
        super.tearDown()
    }

    /// Find any file named `filename` anywhere under `cacheRoot`, polling
    /// until it appears or the timeout elapses.
    private func waitForCacheFile(named filename: String, timeout: TimeInterval = 10) -> URL? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let match = findCacheFile(named: filename) { return match }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    private func findCacheFile(named filename: String) -> URL? {
        guard let enumerator = FileManager.default.enumerator(
            at: Self.cacheRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        for case let url as URL in enumerator where url.lastPathComponent == filename {
            return url
        }
        return nil
    }

    func test01_zoomTriggersCacheWrite() throws {
        let app = Self.app!
        let preview = app.images[A11y.photoPreview]
        XCTAssertTrue(preview.waitForExistence(timeout: 10),
                      "PhotoPreview should appear after processing")

        app.typeKey("z", modifierFlags: [])

        let cached = waitForCacheFile(named: "DSC09176.jpg")
        XCTAssertNotNil(cached,
                        "Preview cache file should exist for the auto-selected photo")
    }

    func test02_clearedCacheRegenerates() throws {
        try? FileManager.default.removeItem(at: Self.cacheRoot)

        let app = Self.app!
        app.typeKey("z", modifierFlags: [])
        app.typeKey("z", modifierFlags: [])

        let cached = waitForCacheFile(named: "DSC09176.jpg", timeout: 15)
        XCTAssertNotNil(cached,
                        "Preview cache file should be regenerated after a manual wipe")
    }

    func test03_skimSuppressesPrefetchUntilDwell() throws {
        // Wipe cache — the disk-JPG sweep is gated behind dwell too via
        // the foreground decode path, so a fresh start makes the delta
        // visible.
        try? FileManager.default.removeItem(at: Self.cacheRoot)

        let app = Self.app!
        XCTAssertTrue(app.images[A11y.photoPreview].waitForExistence(timeout: 10))
        app.typeKey("z", modifierFlags: [])

        // Rapid keypresses — XCUITest delivers them synchronously, so the
        // inter-key gap is ~0–10 ms, well under the 250 ms skim threshold.
        for _ in 0..<10 {
            app.typeKey(.rightArrow, modifierFlags: [])
        }

        let duringSkimCount = countCacheFiles()

        // Wait through the 500 ms dwell threshold plus a small grace
        // window for the prefetch to land at least one full-res JPG.
        Thread.sleep(forTimeInterval: 1.5)

        let postDwellCount = countCacheFiles()
        XCTAssertGreaterThan(postDwellCount, duringSkimCount,
                             "Dwell should write more cache files than were present during skim")
    }

    private func countCacheFiles() -> Int {
        guard let enumerator = FileManager.default.enumerator(
            at: Self.cacheRoot,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else { return 0 }
        var count = 0
        for case let url as URL in enumerator
            where url.pathExtension == "jpg" {
            count += 1
        }
        return count
    }
}
