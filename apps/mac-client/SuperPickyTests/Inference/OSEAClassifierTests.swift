// OSEAClassifierTests.swift
//
// Tests for OSEAClassifier preprocessing helpers.
// Model-free: all tests verify Swift logic only.

import Testing
import CoreGraphics
import Foundation
@testable import SuperPickyInference

struct OSEAClassifierTests {

    // MARK: - Constants

    @Test func classCount() {
        #expect(OSEAClassifier.numClasses == 10964)
        #expect(OSEAClassifier.outputDim == 11000)
        #expect(OSEAClassifier.cropSize == 224)
        #expect(OSEAClassifier.resizeSize == 256)
    }

    // MARK: - Preprocessing

    @Test func preprocessShape() throws {
        // Any-size image → should produce [1, 3, 224, 224] MLMultiArray
        let image = try makeSolid(width: 512, height: 768)
        let array = try OSEAClassifier.preprocess(image: image)
        #expect(array.shape.count == 4)
        #expect(array.shape[0] == 1)
        #expect(array.shape[1] == 3)
        #expect(array.shape[2] == 224)
        #expect(array.shape[3] == 224)
    }

    @Test func preprocessWhiteNormalization() throws {
        // White image (255,255,255) normalized: (1.0 - mean) / std
        // R: (1.0 - 0.485) / 0.229 ≈ 2.249
        let white = try makeSolid(width: 256, height: 256, r: 255, g: 255, b: 255)
        let array = try OSEAClassifier.preprocess(image: white)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: 3 * 224 * 224)
        let rCenter = ptr[0 * 224 * 224 + 112 * 224 + 112]
        let gCenter = ptr[1 * 224 * 224 + 112 * 224 + 112]
        let bCenter = ptr[2 * 224 * 224 + 112 * 224 + 112]
        #expect(abs(rCenter - (1.0 - 0.485) / 0.229) < 0.02)
        #expect(abs(gCenter - (1.0 - 0.456) / 0.224) < 0.02)
        #expect(abs(bCenter - (1.0 - 0.406) / 0.225) < 0.02)
    }

    @Test func preprocessBlackNormalization() throws {
        // Black image (0,0,0) normalized: (0.0 - mean) / std
        // R: (0.0 - 0.485) / 0.229 ≈ -2.118
        let black = try makeSolid(width: 256, height: 256, r: 0, g: 0, b: 0)
        let array = try OSEAClassifier.preprocess(image: black)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: 3 * 224 * 224)
        let rCenter = ptr[0 * 224 * 224 + 112 * 224 + 112]
        #expect(abs(rCenter - (-0.485 / 0.229)) < 0.02)
    }

    @Test func preprocessFreshBuffer() throws {
        // Two calls produce independent MLMultiArrays
        let img = try makeSolid(width: 300, height: 400)
        let a1 = try OSEAClassifier.preprocess(image: img)
        let a2 = try OSEAClassifier.preprocess(image: img)
        // Different objects (no shared mutable state)
        #expect(a1.dataPointer != a2.dataPointer)
    }

    @Test func preprocessSmallImage() throws {
        // Image smaller than cropSize (224) should still produce correct output
        let small = try makeSolid(width: 100, height: 80)
        let array = try OSEAClassifier.preprocess(image: small)
        #expect(array.shape[2] == 224)
        #expect(array.shape[3] == 224)
    }
}

// MARK: - Helpers

private func makeSolid(width: Int, height: Int,
                        r: UInt8 = 128, g: UInt8 = 128, b: UInt8 = 128) throws -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ), let img = {
        ctx.setFillColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        return ctx.makeImage()
    }() else {
        struct Err: Error {}
        throw Err()
    }
    return img
}
