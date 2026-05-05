import Testing
import Foundation
import CoreGraphics
@testable import SuperPicky

@Suite struct ExposureDetectorTests {
    let detector = ExposureDetector()

    @Test func normalExposure() {
        let image = createSolidImage(width: 100, height: 100, gray: 128)
        let result = detector.detect(image: image, threshold: 0.10)
        #expect(result.isOverexposed == false)
        #expect(result.isUnderexposed == false)
    }

    @Test func overexposedImage() {
        let image = createSolidImage(width: 100, height: 100, gray: 250)
        let result = detector.detect(image: image, threshold: 0.10)
        #expect(result.isOverexposed == true)
        #expect(result.overexposedRatio > 0.9)
    }

    @Test func underexposedImage() {
        let image = createSolidImage(width: 100, height: 100, gray: 5)
        let result = detector.detect(image: image, threshold: 0.10)
        #expect(result.isUnderexposed == true)
        #expect(result.underexposedRatio > 0.9)
    }

    private func createSolidImage(width: Int, height: Int, gray: UInt8) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: gray, count: width * height)
        let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: colorSpace, bitmapInfo: 0
        )!
        return context.makeImage()!
    }
}
