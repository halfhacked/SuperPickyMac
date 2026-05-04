import Testing
import CoreGraphics
import Foundation
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

    @Test func segMaskZeroEverywhereForcesScoreToZero() {
        // Bird crop has a high-contrast white square inside a black field —
        // a head circle covering it should report a high gradient. With an
        // all-zeros seg mask the head circle ∩ seg mask is empty, so the
        // Sobel sum has no contributing pixels and the function falls
        // through to the `count == 0` branch returning 0.
        let image = makeTestCGImage()  // 100×100, white square at (20,20)-(80,80)
        let allZero = [UInt8](repeating: 0, count: image.width * image.height)
        let zeroed = HeadSharpness.score(
            birdCrop: image,
            leftEyeX: 0.5, leftEyeY: 0.5, leftEyeVis: 0.9,
            rightEyeX: nil, rightEyeY: nil, rightEyeVis: 0.0,
            beakX: 0.6, beakY: 0.7, beakVis: 0.9,
            segMask: allZero
        )
        #expect(zeroed == 0)
    }

    @Test func segMaskAllOnesMatchesNoMask() {
        // An all-ones mask must not change the score relative to no mask:
        // every in-circle pixel still passes through.
        let image = makeTestCGImage()
        let noMask = HeadSharpness.score(
            birdCrop: image,
            leftEyeX: 0.5, leftEyeY: 0.5, leftEyeVis: 0.9,
            rightEyeX: nil, rightEyeY: nil, rightEyeVis: 0.0,
            beakX: 0.6, beakY: 0.7, beakVis: 0.9
        )
        let allOne = [UInt8](repeating: 1, count: image.width * image.height)
        let withMask = HeadSharpness.score(
            birdCrop: image,
            leftEyeX: 0.5, leftEyeY: 0.5, leftEyeVis: 0.9,
            rightEyeX: nil, rightEyeY: nil, rightEyeVis: 0.0,
            beakX: 0.6, beakY: 0.7, beakVis: 0.9,
            segMask: allOne
        )
        #expect(noMask == withMask)
    }

    @Test func segMaskExcludesBackgroundEdges() {
        // 200×200 image. The "bird body" is a uniform mid-gray patch on
        // the left; the "background" on the right has a high-contrast
        // black/white stripe that produces strong gradients.
        // The eye-centered head circle reaches into both regions.
        // With seg mask = bird-body-only, the high-gradient stripes are
        // excluded and the score must drop.
        let w = 200, h = 200
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        // Solid mid-gray everywhere (low gradient inside the bird body).
        ctx.setFillColor(CGColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        // High-contrast vertical stripes on the right half (background).
        for stripe in 0..<10 {
            let x = w/2 + stripe * 10
            let color = stripe.isMultiple(of: 2) ? 0.0 : 1.0
            ctx.setFillColor(CGColor(red: color, green: color, blue: color, alpha: 1))
            ctx.fill(CGRect(x: x, y: 0, width: 10, height: h))
        }
        let image = ctx.makeImage()!

        // Mask = left-half only (bird body lives there).
        var mask = [UInt8](repeating: 0, count: w * h)
        for y in 0..<h { for x in 0..<(w/2) { mask[y * w + x] = 1 } }

        // Eye and beak both inside the left half; radius spans into the
        // striped right half so the unmasked score is dominated by it.
        let withoutMask = HeadSharpness.score(
            birdCrop: image,
            leftEyeX: 0.30, leftEyeY: 0.5, leftEyeVis: 0.9,
            rightEyeX: nil, rightEyeY: nil, rightEyeVis: 0.0,
            beakX: 0.85, beakY: 0.5, beakVis: 0.9   // far beak → big radius
        )!
        let withMask = HeadSharpness.score(
            birdCrop: image,
            leftEyeX: 0.30, leftEyeY: 0.5, leftEyeVis: 0.9,
            rightEyeX: nil, rightEyeY: nil, rightEyeVis: 0.0,
            beakX: 0.85, beakY: 0.5, beakVis: 0.9,
            segMask: mask
        )!
        #expect(withMask < withoutMask)
    }

    @Test func noBeakBboxFallbackUsesBboxNotCropSize() {
        // 200×200 image with a single high-contrast vertical edge at x=120.
        // Beak hidden → fallback radius branch fires.
        // birdBboxSize.maxSide = 100  → radius = max(10, min(100*0.15=15, 99)) = 15
        // No bbox             → radius = max(10, min(200*0.15=30, 99)) = 30
        // The two radii produce DIFFERENT scores because the no-bbox circle
        // covers more of the edge than the bbox circle.
        let w = 200, h = 200
        let cs = CGColorSpaceCreateDeviceRGB()
        let ctx = CGContext(data: nil, width: w, height: h,
                            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: w, height: h))
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 120, y: 0, width: 1, height: h))
        let image = ctx.makeImage()!

        let withoutBox = HeadSharpness.score(
            birdCrop: image,
            leftEyeX: 0.5, leftEyeY: 0.5, leftEyeVis: 0.9,
            rightEyeX: nil, rightEyeY: nil, rightEyeVis: 0.0,
            beakX: nil, beakY: nil, beakVis: 0.0  // beak hidden → fallback
        )!
        let withBox = HeadSharpness.score(
            birdCrop: image,
            leftEyeX: 0.5, leftEyeY: 0.5, leftEyeVis: 0.9,
            rightEyeX: nil, rightEyeY: nil, rightEyeVis: 0.0,
            beakX: nil, beakY: nil, beakVis: 0.0,
            birdBboxSize: (width: 100, height: 100)
        )!
        // Different radii → different scores. The exact direction depends
        // on whether the edge sits inside the smaller bbox circle; what
        // matters for parity is that the bbox value actually changes the
        // computation rather than being silently ignored.
        #expect(withoutBox != withBox)
    }

    @Test func beakVisibleIgnoresBboxFallback() {
        // When the beak is visible the eye-beak × 1.2 path takes over and
        // birdBboxSize is irrelevant — passing a wildly different bbox
        // size must produce identical scores to omitting it.
        let image = makeTestCGImage()
        let withoutBox = HeadSharpness.score(
            birdCrop: image,
            leftEyeX: 0.5, leftEyeY: 0.5, leftEyeVis: 0.9,
            rightEyeX: nil, rightEyeY: nil, rightEyeVis: 0.0,
            beakX: 0.6, beakY: 0.7, beakVis: 0.9
        )
        let withTinyBox = HeadSharpness.score(
            birdCrop: image,
            leftEyeX: 0.5, leftEyeY: 0.5, leftEyeVis: 0.9,
            rightEyeX: nil, rightEyeY: nil, rightEyeVis: 0.0,
            beakX: 0.6, beakY: 0.7, beakVis: 0.9,
            birdBboxSize: (width: 10, height: 10)
        )
        #expect(withoutBox == withTinyBox)
    }

    @Test func birdCropAlignedSegMaskRejectsMalformedInput() {
        let image = makeTestCGImage(width: 1280, height: 853)
        let bbox = CGRect(x: 0.4, y: 0.4, width: 0.2, height: 0.2)
        // Empty mask → nil
        #expect(PipelineCoordinator.birdCropAlignedSegMask(
            yoloMask: Data(), inferImage: image, bbox: bbox, birdCropSize: 100) == nil)
        // Non-square mask byte count → nil
        let nonSquare = Data(repeating: 1, count: 160 * 161)
        #expect(PipelineCoordinator.birdCropAlignedSegMask(
            yoloMask: nonSquare, inferImage: image, bbox: bbox, birdCropSize: 100) == nil)
    }

    @Test func birdCropAlignedSegMaskAllZerosProducesAllZeros() {
        // Inference image roughly matching the Sony A1 inference frame
        // (1280×853, 3:2 letterbox). Bbox sized so the smart-square crop
        // lands within bounds without the letterbox-fill branch.
        let image = makeTestCGImage(width: 1280, height: 853)
        let bbox = CGRect(x: 0.45, y: 0.40, width: 0.10, height: 0.20)
        let zeros = Data(repeating: 0, count: 160 * 160)
        let out = PipelineCoordinator.birdCropAlignedSegMask(
            yoloMask: zeros, inferImage: image, bbox: bbox, birdCropSize: 196)
        #expect(out != nil)
        #expect(out!.allSatisfy { $0 == 0 })
    }

    @Test func birdCropAlignedSegMaskAllOnesFillsCanvasInterior() {
        // With an all-ones YOLO mask, every bird-crop pixel that maps back
        // into the inference image (i.e. inside the clamped crop region)
        // must be 1. The letterbox-fill margin around the clamped region
        // — pixels outside the inference image — stays 0.
        let image = makeTestCGImage(width: 1280, height: 853)
        // Bbox near the top-left so smart-square clamping triggers the
        // letterbox branch.
        let bbox = CGRect(x: 0.02, y: 0.02, width: 0.18, height: 0.18)
        let ones = Data(repeating: 1, count: 160 * 160)
        let out = PipelineCoordinator.birdCropAlignedSegMask(
            yoloMask: ones, inferImage: image, bbox: bbox, birdCropSize: 264)
        #expect(out != nil)
        // At least *some* pixels must be 1 (the in-canvas region) and at
        // least some must be 0 (the letterbox margin). If the helper is
        // entirely 0 or entirely 1, the geometry math is wrong.
        #expect(out!.contains(where: { $0 == 1 }))
        #expect(out!.contains(where: { $0 == 0 }))
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
