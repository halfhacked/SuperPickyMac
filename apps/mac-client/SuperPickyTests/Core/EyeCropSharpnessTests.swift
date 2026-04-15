import Testing
import CoreGraphics
@testable import SuperPicky

struct EyeCropSharpnessTests {

    private func makeTestCGImage(width: Int = 100, height: Int = 100) -> CGImage {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: width, height: height,
                            bitsPerComponent: 8, bytesPerRow: 0,
                            space: colorSpace,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 20, y: 20, width: 60, height: 60))
        return ctx.makeImage()!
    }

    @Test func bothEyesInvisibleReturnsNil() {
        let image = makeTestCGImage()
        let result = EyeCropSharpness.score(
            birdCrop: image,
            leftEyeX: 0.5, leftEyeY: 0.5, leftEyeVis: 0.1,
            rightEyeX: 0.5, rightEyeY: 0.5, rightEyeVis: 0.1
        )
        #expect(result == nil)
    }

    @Test func leftEyeVisibleReturnsScore() {
        let image = makeTestCGImage()
        let result = EyeCropSharpness.score(
            birdCrop: image,
            leftEyeX: 0.5, leftEyeY: 0.5, leftEyeVis: 0.9,
            rightEyeX: nil, rightEyeY: nil, rightEyeVis: 0.0
        )
        #expect(result != nil)
    }

    @Test func rightEyeChosenWhenHigherVisibility() {
        let image = makeTestCGImage()
        let result = EyeCropSharpness.score(
            birdCrop: image,
            leftEyeX: 0.5, leftEyeY: 0.5, leftEyeVis: 0.5,
            rightEyeX: 0.5, rightEyeY: 0.5, rightEyeVis: 0.8
        )
        #expect(result != nil)
    }

    @Test func nilCoordsWithVisibleEyeFallsThrough() {
        let image = makeTestCGImage()
        let result = EyeCropSharpness.score(
            birdCrop: image,
            leftEyeX: nil, leftEyeY: nil, leftEyeVis: 0.9,
            rightEyeX: 0.5, rightEyeY: 0.5, rightEyeVis: 0.8
        )
        #expect(result != nil)
    }

    @Test func tinyImageReturnsNil() {
        let image = makeTestCGImage(width: 4, height: 4)
        let result = EyeCropSharpness.score(
            birdCrop: image,
            leftEyeX: 0.5, leftEyeY: 0.5, leftEyeVis: 0.9,
            rightEyeX: nil, rightEyeY: nil, rightEyeVis: 0.0
        )
        #expect(result == nil)
    }
}
