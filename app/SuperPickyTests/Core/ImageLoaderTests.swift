import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import SuperPicky

/// Regression tests for `ImageLoader.load(maxPixelSize:)`.
///
/// The reported bug (#47): a large JPG whose only embedded thumbnail is a tiny
/// EXIF thumb (~160 px) was rendered in the preview at the embedded thumb's
/// size and upscaled 10× or more on screen, producing a visibly blurry image.
/// The previous heuristic (`sourceMaxDimension > maxPixelSize` → use the
/// embedded thumb) didn't account for the embedded thumb's actual size.
///
/// The test exercises the exact failure mode: a source whose longest side
/// exceeds `maxPixelSize` but whose embedded thumbnail is far smaller than
/// `maxPixelSize`. The decode must fall back to the full image.
struct ImageLoaderTests {
    @Test
    func largeJPGWithTinyEmbeddedThumbnail_decodesFullImageNotThumb() async throws {
        let dir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("large-with-tiny-thumb.jpg")
        createJPEGWithEmbeddedThumbnail(at: path, sidePixels: 3000)

        // Sanity-check the fixture: the JPG must actually embed a thumbnail
        // whose longest side is far smaller than our preview target. If this
        // fails, ImageIO's `EmbedThumbnail` behavior changed and the test
        // no longer exercises the bug path — fail loudly rather than silently
        // passing against the old heuristic.
        let src = try #require(CGImageSourceCreateWithURL(path as CFURL, nil))
        let embedded = try #require(
            CGImageSourceCreateThumbnailAtIndex(src, 0, [
                kCGImageSourceThumbnailMaxPixelSize: 99_999,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
                kCGImageSourceCreateThumbnailFromImageAlways: false,
            ] as CFDictionary),
            "Fixture JPEG did not get an embedded thumbnail; ImageIO's EmbedThumbnail option may have changed."
        )
        let embeddedSide = max(embedded.width, embedded.height)
        #expect(
            embeddedSide < 500,
            "Fixture embedded thumb must be much smaller than maxPixelSize to exercise the bug path (got \(embeddedSide) px)."
        )

        let maxPixelSize = 2000
        let cg = try #require(
            await ImageLoader.loadCGImage(path: path.path, maxPixelSize: maxPixelSize)
        )
        let longestSide = max(cg.width, cg.height)

        // The preview must be decoded from the full image (~maxPixelSize on
        // its longest side), not the 160-ish px embedded thumbnail. Allow a
        // small margin: ImageIO may round the computed thumbnail size when
        // the requested max doesn't land on a clean aspect-ratio pixel.
        #expect(
            longestSide > embeddedSide * 2,
            "Preview longest side (\(longestSide) px) must be much larger than the embedded thumb (\(embeddedSide) px) — otherwise the tiny thumb was upscaled and the preview is blurry."
        )
        #expect(
            longestSide <= maxPixelSize,
            "Preview longest side (\(longestSide) px) must not exceed maxPixelSize (\(maxPixelSize) px)."
        )
    }

    // MARK: - Fixture helpers

    /// Write a solid-pattern JPEG whose container embeds a small EXIF
    /// thumbnail (via ImageIO's `kCGImageDestinationEmbedThumbnail`). The
    /// resulting file reproduces the bug: a large main image with a
    /// disproportionately tiny embedded thumbnail.
    private func createJPEGWithEmbeddedThumbnail(at url: URL, sidePixels: Int) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: sidePixels, height: sidePixels,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        // High-contrast pattern. Keeps the encoded JPEG large enough that the
        // downsampled 2000 px result is meaningfully different from the
        // upscaled 160 px embedded thumb (if the bug regressed).
        context.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        context.fill(CGRect(x: 0, y: 0, width: sidePixels, height: sidePixels))
        context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        let stride = sidePixels / 20
        for i in 0..<20 {
            for j in 0..<20 where (i + j) % 2 == 0 {
                context.fill(CGRect(x: i * stride, y: j * stride, width: stride, height: stride))
            }
        }
        let image = context.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, [
            kCGImageDestinationEmbedThumbnail: true,
        ] as CFDictionary)
        CGImageDestinationFinalize(dest)
    }
}
