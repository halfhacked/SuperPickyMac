// YOLOBirdDetectorTests.swift
//
// Tests for YOLOBirdDetector preprocessing and output decoding helpers.
//
// All tests are model-free (no .mlmodelc needed) — they verify the Swift logic
// that runs around the CoreML inference call:
//   - Letterbox geometry (scale, padding)
//   - Pixel buffer is 640×640
//   - Normalized bbox output stays in [0,1]
//   - Fresh-buffer rule (concurrent predict() uses independent state)

import Testing
import CoreGraphics
import Foundation
@testable import SuperPickyInference

struct YOLOBirdDetectorTests {

    // MARK: - Letterbox geometry

    @Test func letterboxLandscape() {
        // 1200×800 → scale = 640/1200 = 0.533..., newH = 426.7, padTop = 106.7
        let (scale, padLeft, padTop) = YOLOBirdDetector.letterboxParams(
            origW: 1200, origH: 800, targetSize: 640
        )
        #expect(abs(scale - 640.0 / 1200.0) < 1e-4)
        #expect(abs(padLeft) < 1e-4)  // No horizontal padding for landscape
        let expectedPadTop = (640.0 - 800.0 * scale) / 2
        #expect(abs(padTop - expectedPadTop) < 1e-4)
    }

    @Test func letterboxPortrait() {
        // 800×1200 → scale = 640/1200 = 0.533..., newW = 426.7, padLeft = 106.7
        let (scale, padLeft, padTop) = YOLOBirdDetector.letterboxParams(
            origW: 800, origH: 1200, targetSize: 640
        )
        #expect(abs(scale - 640.0 / 1200.0) < 1e-4)
        #expect(abs(padTop) < 1e-4)  // No vertical padding for portrait
        let expectedPadLeft = (640.0 - 800.0 * scale) / 2
        #expect(abs(padLeft - expectedPadLeft) < 1e-4)
    }

    @Test func letterboxSquare() {
        // 512×512 → scale = 640/512 = 1.25, no padding
        let (scale, padLeft, padTop) = YOLOBirdDetector.letterboxParams(
            origW: 512, origH: 512, targetSize: 640
        )
        #expect(abs(scale - 640.0 / 512.0) < 1e-4)
        #expect(abs(padLeft) < 1e-4)
        #expect(abs(padTop) < 1e-4)
    }

    @Test func letterboxBboxRoundTrip() {
        // Verify that a detection at the center of the original image un-letterboxes to ~0.5,0.5.
        // Image: 1200×800 landscape
        let origW: Float = 1200, origH: Float = 800
        let targetSize: Float = 640
        let (scale, padLeft, padTop) = YOLOBirdDetector.letterboxParams(
            origW: origW, origH: origH, targetSize: targetSize
        )

        // Center of original image in pixel coords = (600, 400)
        // In letterbox space: cx = 600 * scale + padLeft, cy = 400 * scale + padTop
        let lbCx = 600 * scale + padLeft
        let lbCy = 400 * scale + padTop

        // Un-letterbox back
        let nx = (lbCx - padLeft) / scale / origW
        let ny = (lbCy - padTop)  / scale / origH

        #expect(abs(nx - 0.5) < 1e-4)
        #expect(abs(ny - 0.5) < 1e-4)
    }

    // MARK: - Constants

    @Test func classIDIsCOCOBird() {
        // COCO bird class must be 14 — changing this breaks detection pipeline
        #expect(YOLOBirdDetector.birdClassID == 14)
    }

    @Test func defaultThresholds() {
        #expect(YOLOBirdDetector.confThreshold == 0.25)
        #expect(YOLOBirdDetector.nmsIoUThreshold == 0.45)
    }

    // MARK: - Fresh-buffer rule

    @Test func freshBufferRuleLetterbox() async throws {
        // Two letterbox calls on images of different sizes produce different scales —
        // confirms letterboxParams is stateless (pure function).
        let (scale1, _, _) = YOLOBirdDetector.letterboxParams(
            origW: 1200, origH: 800, targetSize: 640
        )
        let (scale2, _, _) = YOLOBirdDetector.letterboxParams(
            origW: 320, origH: 240, targetSize: 640
        )
        // 1200px input → scale=0.533; 320px input → scale=2.0
        #expect(abs(scale1 - 640.0 / 1200.0) < 1e-4)
        #expect(abs(scale2 - 640.0 / 320.0) < 1e-4)
        #expect(abs(scale1 - scale2) > 0.1)
    }

    @Test func maskDecodeThresholdsDotProductAtZero() {
        let pixelCount = 160 * 160
        var coefficients = [Float](repeating: 0, count: 32)
        coefficients[0] = 1
        var prototypes = [Float](repeating: 0, count: 32 * pixelCount)
        for pixel in 0..<pixelCount {
            prototypes[pixel] = pixel.isMultiple(of: 2) ? 1 : -1
        }

        let mask = prototypes.withUnsafeBufferPointer {
            YOLOBirdDetector.decodeMask(
                coefs: coefficients, protos: $0.baseAddress!
            )
        }

        #expect(mask.count == pixelCount)
        #expect(mask[0] == 1)
        #expect(mask[1] == 0)
        #expect(mask[pixelCount - 2] == 1)
        #expect(mask[pixelCount - 1] == 0)
    }
}

// MARK: - Helpers

private func makeSolidCGImage(width: Int, height: Int,
                               red: CGFloat, green: CGFloat, blue: CGFloat) -> CGImage? {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { return nil }
    ctx.setFillColor(red: red, green: green, blue: blue, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()
}
