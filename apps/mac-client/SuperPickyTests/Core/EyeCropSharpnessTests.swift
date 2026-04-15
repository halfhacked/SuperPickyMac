import Testing
import CoreGraphics
@testable import SuperPicky

struct HeadSharpnessTests {

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

    @Test func bothEyesInvisibleReturnsScoreNotNil() {
        let image = makeTestCGImage()
        let result = HeadSharpness.score(
            birdCrop: image,
            leftEyeX: 0.5, leftEyeY: 0.5, leftEyeVis: 0.1,
            rightEyeX: 0.5, rightEyeY: 0.5, rightEyeVis: 0.1,
            beakX: 0.6, beakY: 0.7, beakVis: 0.9
        )
        // Both eyes hidden → still returns a score (with 0.8x penalty), not nil
        // Score may be 0 on synthetic image (uniform region under mask), but not nil
        #expect(result != nil)
    }

    @Test func leftEyeVisibleReturnsScore() {
        let image = makeTestCGImage()
        let result = HeadSharpness.score(
            birdCrop: image,
            leftEyeX: 0.5, leftEyeY: 0.5, leftEyeVis: 0.9,
            rightEyeX: nil, rightEyeY: nil, rightEyeVis: 0.0,
            beakX: 0.6, beakY: 0.7, beakVis: 0.9
        )
        #expect(result != nil)
    }

    @Test func bothEyesNilReturnsNil() {
        let image = makeTestCGImage()
        let result = HeadSharpness.score(
            birdCrop: image,
            leftEyeX: nil, leftEyeY: nil, leftEyeVis: 0.0,
            rightEyeX: nil, rightEyeY: nil, rightEyeVis: 0.0,
            beakX: 0.5, beakY: 0.5, beakVis: 0.9
        )
        #expect(result == nil)
    }

    @Test func tinyImageReturnsNil() {
        let image = makeTestCGImage(width: 4, height: 4)
        let result = HeadSharpness.score(
            birdCrop: image,
            leftEyeX: 0.5, leftEyeY: 0.5, leftEyeVis: 0.9,
            rightEyeX: nil, rightEyeY: nil, rightEyeVis: 0.0,
            beakX: 0.6, beakY: 0.7, beakVis: 0.9
        )
        #expect(result == nil)
    }

    @Test func isoSharpnessFactor() {
        // ISO <= 800 → 1.0
        #expect(PipelineCoordinator.isoSharpnessFactor(iso: 100) == 1.0)
        #expect(PipelineCoordinator.isoSharpnessFactor(iso: 800) == 1.0)
        #expect(PipelineCoordinator.isoSharpnessFactor(iso: nil) == 1.0)
        // ISO 1600 → 0.95
        #expect(abs(PipelineCoordinator.isoSharpnessFactor(iso: 1600) - 0.95) < 0.01)
        // ISO 6400 → 0.85
        #expect(abs(PipelineCoordinator.isoSharpnessFactor(iso: 6400) - 0.85) < 0.01)
        // Floor at 0.5
        #expect(PipelineCoordinator.isoSharpnessFactor(iso: 999999) >= 0.5)
    }
}
