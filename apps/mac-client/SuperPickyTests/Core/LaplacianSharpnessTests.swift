import Testing
import CoreGraphics
@testable import SuperPicky

@Suite struct LaplacianSharpnessTests {

    // Helper: create a solid-color 64×64 CGImage
    private func solidColorImage(gray: UInt8) -> CGImage {
        let w = 64, h = 64
        var pixels = [UInt8](repeating: gray, count: w * h)
        let ctx = CGContext(data: &pixels, width: w, height: h,
                           bitsPerComponent: 8, bytesPerRow: w,
                           space: CGColorSpaceCreateDeviceGray(),
                           bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return ctx.makeImage()!
    }

    // Helper: create a 64×64 checkerboard (alternating 0/255 in each pixel)
    private func checkerboardImage() -> CGImage {
        let w = 64, h = 64
        var pixels = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                pixels[y * w + x] = UInt8((x + y) % 2 == 0 ? 255 : 0)
            }
        }
        let ctx = CGContext(data: &pixels, width: w, height: h,
                           bitsPerComponent: 8, bytesPerRow: w,
                           space: CGColorSpaceCreateDeviceGray(),
                           bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        return ctx.makeImage()!
    }

    @Test func solidColorImageScoresZero() {
        let image = solidColorImage(gray: 200)
        let score = LaplacianSharpness.score(image: image)
        // Solid color has zero gradient everywhere → Laplacian = 0 → variance = 0
        #expect(score < 1.0)
    }

    @Test func checkerboardScoresHigher() {
        let image = checkerboardImage()
        let score = LaplacianSharpness.score(image: image)
        // Maximum-frequency pattern → very high Laplacian variance → high score
        #expect(score > 100)
    }

    @Test func checkerboardScoresHigherThanBlur() {
        let sharpImage = checkerboardImage()
        let blurImage = solidColorImage(gray: 128)
        #expect(LaplacianSharpness.score(image: sharpImage) > LaplacianSharpness.score(image: blurImage))
    }

    @Test func scoreIsCapped() {
        let image = checkerboardImage()
        let score = LaplacianSharpness.score(image: image)
        // Score must never exceed 600
        #expect(score <= 600)
    }

    @Test func tinyImageReturnsZero() {
        let w = 2, h = 2
        var pixels = [UInt8](repeating: 128, count: w * h)
        let ctx = CGContext(data: &pixels, width: w, height: h,
                           bitsPerComponent: 8, bytesPerRow: w,
                           space: CGColorSpaceCreateDeviceGray(),
                           bitmapInfo: CGImageAlphaInfo.none.rawValue)!
        let image = ctx.makeImage()!
        // No interior pixels → guard fails → 0
        #expect(LaplacianSharpness.score(image: image) == 0)
    }
}
