import Testing
import CoreGraphics
@testable import SuperPicky

@Suite struct TenengradSharpnessTests {

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

    // Helper: create a 256×256 image with sharp vertical edges (4px stripe width)
    private func sharpEdgesImage() -> CGImage {
        let w = 256, h = 256
        var pixels = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h {
            for x in 0..<w {
                pixels[y * w + x] = (x / 4) % 2 == 0 ? 255 : 0
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
        let score = TenengradSharpness.score(image: image)
        // Solid color has zero gradient everywhere → score = 0
        #expect(score < 1.0)
    }

    @Test func checkerboardScoresHigher() {
        let image = sharpEdgesImage()
        let score = TenengradSharpness.score(image: image)
        // Maximum-frequency pattern → very high Sobel gradient → high score
        #expect(score > 100)
    }

    @Test func checkerboardScoresHigherThanBlur() {
        let sharpImage = sharpEdgesImage()
        let blurImage = solidColorImage(gray: 128)
        #expect(TenengradSharpness.score(image: sharpImage) > TenengradSharpness.score(image: blurImage))
    }

    @Test func scoreIsCapped() {
        let image = sharpEdgesImage()
        let score = TenengradSharpness.score(image: image)
        // Score must never exceed 1000
        #expect(score <= 1000)
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
        #expect(TenengradSharpness.score(image: image) == 0)
    }
}
