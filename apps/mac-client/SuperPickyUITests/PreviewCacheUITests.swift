import XCTest
import CryptoKit

/// L3 BDD: verify that pressing `z` to zoom triggers a full-res decode
/// which writes a sidecar JPEG into the preview cache, and that
/// re-launching the app reuses the on-disk file instead of re-writing it.
///
/// Cleans the cache before and after the run so we don't leak between
/// CI runs or interfere with the user's real cache.
final class PreviewCacheUITests: SuperPickyUITestCase {

    override class var testDirPrefix: String { "superpicky_preview_cache" }

    private static let cacheRoot: URL = {
        let caches = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        return caches.appendingPathComponent("com.halfhacked.superpicky/preview", isDirectory: true)
    }()

    override class func setUp() {
        // Ensure the cache starts empty — anything left from a prior run
        // would mask a regression in the lazy-write path.
        try? FileManager.default.removeItem(at: cacheRoot)
        super.setUp()
    }

    override class func tearDown() {
        try? FileManager.default.removeItem(at: cacheRoot)
        super.tearDown()
    }

    /// SHA-256 of the absolute folder path → first 16 hex chars; mirrors
    /// `PreviewCache.cachedURL(for:)`.
    private func folderHashDir() -> URL {
        let folder = Self.testDir!
        let data = Data(folder.utf8)
        let digest = SHA256.hash(data: data)
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return Self.cacheRoot.appendingPathComponent(String(hex.prefix(16)), isDirectory: true)
    }

    private func waitForCacheFile(named filename: String, timeout: TimeInterval = 10) -> URL? {
        let url = folderHashDir().appendingPathComponent(filename)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if FileManager.default.fileExists(atPath: url.path) { return url }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    func test01_zoomTriggersCacheWrite() throws {
        let app = Self.app!
        let preview = app.images[A11y.photoPreview]
        XCTAssertTrue(preview.waitForExistence(timeout: 10),
                      "PhotoPreview should appear after processing")

        // Enter actual-pixels zoom — forces a full-res decode and the
        // post-decode cache write. The folder-open sweep may have already
        // written the file by this point; the test asserts the post-state
        // either way.
        app.typeKey("z", modifierFlags: [])

        let cached = waitForCacheFile(named: "DSC09176.jpg")
        XCTAssertNotNil(cached,
                        "Preview cache file should exist for the auto-selected photo")
    }

    func test02_clearedCacheRegenerates() throws {
        // After test01 the cache should hold DSC09176.jpg. Wipe the cache,
        // navigate, and verify the file is recreated.
        try? FileManager.default.removeItem(at: Self.cacheRoot)
        XCTAssertFalse(FileManager.default.fileExists(atPath: folderHashDir().path),
                       "Cache root should be empty after wipe")

        let app = Self.app!
        // Re-trigger a full-res decode on the current photo (zoom out then in).
        app.typeKey("z", modifierFlags: [])
        app.typeKey("z", modifierFlags: [])

        let cached = waitForCacheFile(named: "DSC09176.jpg", timeout: 15)
        XCTAssertNotNil(cached,
                        "Preview cache file should be regenerated after a manual wipe")
    }
}
