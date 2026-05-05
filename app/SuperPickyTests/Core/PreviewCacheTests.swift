import Testing
import Foundation
import ImageIO
import CoreGraphics
@testable import SuperPicky

@Suite(.serialized) struct PreviewCacheTests {

    init() {
        // Redirect the cache root to a per-suite temp directory so tests
        // don't touch ~/Library/Caches/com.halfhacked.superpicky/preview/
        // (the developer's real cache from running the app).
        PreviewCache.rootURLOverride = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewCacheTests/\(UUID().uuidString)/cache")
    }

    // MARK: - Fixtures

    private func makeTempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent("PreviewCacheTests/\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private struct FixtureError: Error { let message: String }

    /// Write a tiny solid-color JPEG so we have a real raw-mtime baseline.
    @discardableResult
    private func writeJPEG(at url: URL, sideLength: Int = 16) throws -> URL {
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil,
            width: sideLength,
            height: sideLength,
            bitsPerComponent: 8,
            bytesPerRow: sideLength * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let image = ctx.makeImage() else {
            throw FixtureError(message: "CGContext / makeImage failed")
        }
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil) else {
            throw FixtureError(message: "CGImageDestinationCreateWithURL failed")
        }
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))
        return url
    }

    /// Make a 1x1 CGImage we can pass to PreviewCache.write.
    private func makePixel() throws -> CGImage {
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
        ), let image = ctx.makeImage() else {
            throw FixtureError(message: "1x1 CGContext failed")
        }
        return image
    }

    // MARK: - cachedURL / freshURL

    @Test func cachedURLLayoutMatchesFolderHash() throws {
        let folder = try makeTempFolder()
        let a = folder.appendingPathComponent("DSC09176.ARW").path
        let b = folder.appendingPathComponent("DSC09177.ARW").path
        let urlA = PreviewCache.cachedURL(for: a)
        let urlB = PreviewCache.cachedURL(for: b)
        #expect(urlA.deletingLastPathComponent() == urlB.deletingLastPathComponent(),
                "same-folder photos must share a hash dir")
        #expect(urlA.lastPathComponent == "DSC09176.jpg")
        #expect(urlB.lastPathComponent == "DSC09177.jpg")
        #expect(urlA.path.hasPrefix(PreviewCache.rootURL.path))
    }

    @Test func freshURLReturnsNilWhenMissing() throws {
        let folder = try makeTempFolder()
        let raw = folder.appendingPathComponent("a.jpg")
        try writeJPEG(at: raw)
        // Cache file has not been written yet.
        #expect(PreviewCache.freshURL(for: raw.path) == nil)
    }

    @Test func freshURLDetectsStaleCache() throws {
        let folder = try makeTempFolder()
        let raw = folder.appendingPathComponent("a.jpg")
        try writeJPEG(at: raw)
        let cached = PreviewCache.cachedURL(for: raw.path)
        try FileManager.default.createDirectory(
            at: cached.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try writeJPEG(at: cached)
        // Backdate cache to be older than raw.
        let oldDate = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: oldDate], ofItemAtPath: cached.path)
        let newDate = Date()
        try FileManager.default.setAttributes([.modificationDate: newDate], ofItemAtPath: raw.path)

        #expect(PreviewCache.freshURL(for: raw.path) == nil,
                "stale cache must not be reported as fresh")

        _ = PreviewCache.clearAll()
    }

    @Test func freshURLAcceptsCurrentCache() throws {
        let folder = try makeTempFolder()
        let raw = folder.appendingPathComponent("a.jpg")
        try writeJPEG(at: raw)
        let cached = PreviewCache.cachedURL(for: raw.path)
        try writeJPEG(at: cached)
        // cached mtime is "now" — equal-or-newer than raw.

        #expect(PreviewCache.freshURL(for: raw.path) != nil)
        _ = PreviewCache.clearAll()
    }

    // MARK: - touch

    @Test func touchUpdatesMtimeOnRead() throws {
        let folder = try makeTempFolder()
        let raw = folder.appendingPathComponent("a.jpg")
        try writeJPEG(at: raw)
        let cached = PreviewCache.cachedURL(for: raw.path)
        try writeJPEG(at: cached)
        let before = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: before], ofItemAtPath: cached.path)

        PreviewCache.touch(cached)

        let attrs = try FileManager.default.attributesOfItem(atPath: cached.path)
        let after = attrs[.modificationDate] as? Date
        #expect(after != nil)
        if let after { #expect(after.timeIntervalSince(before) > 30) }

        _ = PreviewCache.clearAll()
    }

    // MARK: - eviction

    @Test func evictDropsOldestUntilUnderCap() throws {
        // Wipe cache so we don't see leftover state from other tests.
        _ = PreviewCache.clearAll()

        // Synthesize 5 cache entries with known mtimes.
        let now = Date()
        var urls: [URL] = []
        for i in 0..<5 {
            // Fabricate paths so each gets a unique cache filename.
            let fakePath = "/tmp/PreviewCacheTests/fake/\(i).ARW"
            let url = PreviewCache.cachedURL(for: fakePath)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            // 200 KB each with mtime spaced 1 hour apart.
            let data = Data(count: 200_000)
            try data.write(to: url)
            let mtime = now.addingTimeInterval(TimeInterval(-3600 * (5 - i)))
            try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: url.path)
            urls.append(url)
        }

        let totalBefore = PreviewCache.currentSizeBytes()
        #expect(totalBefore == 5 * 200_000)

        // Cap at 600 KB → target 540 KB → evict ~3 oldest files.
        PreviewCache.evictIfOverCap(maxBytes: 600_000)
        let after = PreviewCache.currentSizeBytes()
        #expect(after <= 600_000)
        // Oldest entry (index 0) must be gone; newest (index 4) must remain.
        #expect(!FileManager.default.fileExists(atPath: urls[0].path))
        #expect(FileManager.default.fileExists(atPath: urls[4].path))

        _ = PreviewCache.clearAll()
    }

    @Test func evictNoopWhenUnderCap() throws {
        _ = PreviewCache.clearAll()
        let url = PreviewCache.cachedURL(for: "/tmp/PreviewCacheTests/fake/x.ARW")
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data(count: 100).write(to: url)
        PreviewCache.evictIfOverCap(maxBytes: 1_000_000)
        #expect(FileManager.default.fileExists(atPath: url.path))
        _ = PreviewCache.clearAll()
    }

    // MARK: - write

    @Test func writeProducesReadableJPEG() throws {
        _ = PreviewCache.clearAll()
        let url = PreviewCache.cachedURL(for: "/tmp/PreviewCacheTests/fake/y.ARW")
        let pixel = try makePixel()
        #expect(PreviewCache.write(pixel, to: url))
        #expect(FileManager.default.fileExists(atPath: url.path))
        // Round-trip through ImageIO.
        let source = CGImageSourceCreateWithURL(url as CFURL, nil)
        #expect(source != nil)
        _ = PreviewCache.clearAll()
    }
}
