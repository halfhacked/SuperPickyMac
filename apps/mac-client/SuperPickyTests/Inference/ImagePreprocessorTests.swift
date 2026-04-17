// ImagePreprocessorTests.swift
//
// Verifies the Accelerate-backed preprocessor used by every CoreML wrapper:
//   - Output values match the scalar `(pixel/255 - mean) / std` definition.
//   - Horizontal flip along the W axis is a true reversal.

import Testing
import CoreGraphics
import Foundation
import simd
@testable import SuperPickyInference

struct ImagePreprocessorTests {

    // MARK: - normalizedNCHW

    @Test func normalizedShape() throws {
        let img = try solidImage(width: 100, height: 100, r: 128, g: 128, b: 128)
        let arr = try ImagePreprocessor.normalizedNCHW(image: img, size: 64)
        #expect(arr.shape.map { $0.intValue } == [1, 3, 64, 64])
        #expect(arr.dataType == .float32)
    }

    @Test func whiteNormalizedMatchesImageNet() throws {
        // (1.0 - mean) / std per channel
        let white = try solidImage(width: 64, height: 64, r: 255, g: 255, b: 255)
        let arr = try ImagePreprocessor.normalizedNCHW(image: white, size: 64)
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: 3 * 64 * 64)
        let mid = 32 * 64 + 32
        let expectR = (1.0 - 0.485) / 0.229
        let expectG = (1.0 - 0.456) / 0.224
        let expectB = (1.0 - 0.406) / 0.225
        #expect(abs(ptr[0 * 64 * 64 + mid] - Float(expectR)) < 1e-4)
        #expect(abs(ptr[1 * 64 * 64 + mid] - Float(expectG)) < 1e-4)
        #expect(abs(ptr[2 * 64 * 64 + mid] - Float(expectB)) < 1e-4)
    }

    @Test func zeroMeanUnitStdReturnsPixelsDividedBy255() throws {
        // When mean=(0,0,0) and std=(1,1,1) the output is pixel/255 —
        // this is the aesthetics path, which applies its own normalization.
        let mid = try solidImage(width: 32, height: 32, r: 128, g: 64, b: 200)
        let arr = try ImagePreprocessor.normalizedNCHW(
            image: mid, size: 32,
            mean: SIMD3<Float>(0, 0, 0), std: SIMD3<Float>(1, 1, 1)
        )
        let ptr = arr.dataPointer.bindMemory(to: Float.self, capacity: 3 * 32 * 32)
        let i = 16 * 32 + 16
        #expect(abs(ptr[0 * 32 * 32 + i] - 128.0 / 255.0) < 1e-4)
        #expect(abs(ptr[1 * 32 * 32 + i] -  64.0 / 255.0) < 1e-4)
        #expect(abs(ptr[2 * 32 * 32 + i] - 200.0 / 255.0) < 1e-4)
    }

    // MARK: - horizontalFlipNCHW

    @Test func horizontalFlipReversesEachRow() throws {
        // Half-red / half-blue source: after flip the halves swap on the R/B planes.
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: 32, height: 32,
            bitsPerComponent: 8, bytesPerRow: 32 * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw CancellationError() }
        ctx.setFillColor(red: 1, green: 0, blue: 0, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 32))  // left = red
        ctx.setFillColor(red: 0, green: 0, blue: 1, alpha: 1)
        ctx.fill(CGRect(x: 16, y: 0, width: 16, height: 32)) // right = blue
        guard let img = ctx.makeImage() else { throw CancellationError() }

        let arr = try ImagePreprocessor.normalizedNCHW(
            image: img, size: 32,
            mean: SIMD3<Float>(0, 0, 0), std: SIMD3<Float>(1, 1, 1)
        )
        let flipped = try ImagePreprocessor.horizontalFlipNCHW(arr)

        let orig = arr.dataPointer.bindMemory(to: Float.self, capacity: 3 * 32 * 32)
        let flip = flipped.dataPointer.bindMemory(to: Float.self, capacity: 3 * 32 * 32)

        // For each of R/G/B and each row y, flipped[y, x] == orig[y, 31 - x]
        for c in 0..<3 {
            for y in 0..<32 {
                for x in 0..<32 {
                    let o = orig[c * 32 * 32 + y * 32 + (31 - x)]
                    let f = flip[c * 32 * 32 + y * 32 + x]
                    #expect(abs(o - f) < 1e-6)
                }
            }
        }
    }

    @Test func flipPreservesShape() throws {
        let img = try solidImage(width: 64, height: 64, r: 128, g: 128, b: 128)
        let arr = try ImagePreprocessor.normalizedNCHW(image: img, size: 64)
        let flipped = try ImagePreprocessor.horizontalFlipNCHW(arr)
        #expect(flipped.shape.map { $0.intValue } == arr.shape.map { $0.intValue })
    }
}

private func solidImage(width: Int, height: Int,
                        r: UInt8, g: UInt8, b: UInt8) throws -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    guard let ctx = CGContext(
        data: nil, width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: width * 4,
        space: cs,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { throw CancellationError() }
    ctx.setFillColor(red: CGFloat(r)/255, green: CGFloat(g)/255, blue: CGFloat(b)/255, alpha: 1)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    guard let img = ctx.makeImage() else { throw CancellationError() }
    return img
}
