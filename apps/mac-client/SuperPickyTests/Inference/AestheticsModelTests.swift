// AestheticsModelTests.swift
//
// Tests for AestheticsModel preprocessing helpers.
// Model-free: all tests verify Swift logic only.

import Testing
import CoreML
import CoreGraphics
import Foundation
@testable import SuperPickyInference

struct AestheticsModelTests {

    // MARK: - Constants

    @Test func imageSize() {
        #expect(AestheticsModel.imageSize == 384)
    }

    // MARK: - Preprocessing shape

    @Test func preprocessShape() throws {
        let image = try makeSolid(width: 512, height: 768)
        let array = try AestheticsModel.preprocess(image: image)
        // Should produce [1, 3, 384, 384]
        #expect(array.shape.count == 4)
        #expect(array.shape[0] == 1)
        #expect(array.shape[1] == 3)
        #expect(array.shape[2] == 384)
        #expect(array.shape[3] == 384)
    }

    // MARK: - Normalization range [0, 1]
    // CFANet normalizes internally; preprocess outputs raw [0,1] floats.

    @Test func preprocessWhiteIsOne() throws {
        let white = try makeSolid(width: 400, height: 400, r: 255, g: 255, b: 255)
        let array = try AestheticsModel.preprocess(image: white)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: 3 * 384 * 384)
        let size = 384
        let center = size / 2 * size + size / 2
        let r = ptr[0 * size * size + center]
        let g = ptr[1 * size * size + center]
        let b = ptr[2 * size * size + center]
        #expect(abs(r - 1.0) < 0.01)
        #expect(abs(g - 1.0) < 0.01)
        #expect(abs(b - 1.0) < 0.01)
    }

    @Test func preprocessBlackIsZero() throws {
        let black = try makeSolid(width: 400, height: 400, r: 0, g: 0, b: 0)
        let array = try AestheticsModel.preprocess(image: black)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: 3 * 384 * 384)
        let size = 384
        let center = size / 2 * size + size / 2
        let r = ptr[0 * size * size + center]
        #expect(abs(r - 0.0) < 0.01)
    }

    @Test func preprocessMidGrayIsHalf() throws {
        // (128/255) ≈ 0.502
        let gray = try makeSolid(width: 400, height: 400, r: 128, g: 128, b: 128)
        let array = try AestheticsModel.preprocess(image: gray)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: 3 * 384 * 384)
        let size = 384
        let center = size / 2 * size + size / 2
        let r = ptr[0 * size * size + center]
        #expect(abs(r - Float(128) / 255.0) < 0.01)
    }

    // MARK: - Fresh buffers

    @Test func preprocessFreshBuffer() throws {
        let img = try makeSolid(width: 300, height: 400)
        let a1 = try AestheticsModel.preprocess(image: img)
        let a2 = try AestheticsModel.preprocess(image: img)
        #expect(a1.dataPointer != a2.dataPointer)
    }

    // MARK: - Small image (below 384)

    @Test func preprocessSmallImage() throws {
        let small = try makeSolid(width: 100, height: 80)
        let array = try AestheticsModel.preprocess(image: small)
        #expect(array.shape[2] == 384)
        #expect(array.shape[3] == 384)
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
