// AestheticsModel.swift
//
// Wraps the CoreML CFANet/TOPIQ aesthetics scorer.
//
// Architecture: CFANet (ResNet50 backbone + Transformer cross-attention)
// Source: topiq_model.py with bicubic→bilinear positional-embedding patch
//         (parity delta < 1e-6 vs PyTorch)
//
// Input:  Any-size CGImage, resized to 384×384 in [0,1] float (no ImageNet norm)
//         CFANet applies its own normalization internally in preprocess()
// Output: 10-class probability distribution (AVA score bins 1-10)
//         MOS = Σ (i+1) * dist[i]  for i in 0..<10
//         AestheticsResponse.score = MOS (1-10), .distribution = dist (10 floats)
//
// Thread safety: @unchecked Sendable. MLModel is thread-safe per Apple docs.
// Each score() call allocates a fresh pixel buffer and MLMultiArray.

import CoreML
import CoreGraphics
import Foundation
import os

public final class AestheticsModel: @unchecked Sendable {

    public static let imageSize = 384
    private static let numBins = 10
    private static let outputName = "dist_score"

    private let model: MLModel
    private let logger = Logger(subsystem: "com.superpicky.mac", category: "AestheticsModel")

    public init(url: URL, configuration: MLModelConfiguration = .init()) throws {
        configuration.computeUnits = .all
        self.model = try MLModel(contentsOf: url, configuration: configuration)
    }

    // MARK: - Inference

    /// Returns MOS score [1,10] and 10-bin probability distribution.
    public func score(image: CGImage) throws -> (mos: Float, distribution: [Float]) {
        let inputArray = try Self.preprocess(image: image)
        let input = try MLDictionaryFeatureProvider(dictionary: ["input": inputArray])
        let output = try autoreleasepool { try model.prediction(from: input) }

        guard let distMLA = output.featureValue(for: Self.outputName)?.multiArrayValue else {
            throw AestheticsModelError.missingOutput(Self.outputName)
        }

        let ptr = distMLA.dataPointer.bindMemory(to: Float.self, capacity: Self.numBins)
        let dist = Array(UnsafeBufferPointer(start: ptr, count: Self.numBins))

        // MOS = weighted sum, scores 1-10
        let mos: Float = (0..<Self.numBins).reduce(0) { acc, i in
            acc + Float(i + 1) * dist[i]
        }
        return (mos: max(1, min(10, mos)), distribution: dist)
    }

    // MARK: - Preprocessing

    /// Resize to 384×384 and pack into [1,3,384,384] float32 in [0,1] range.
    /// CFANet applies its own ImageNet normalization internally.
    static func preprocess(image: CGImage) throws -> MLMultiArray {
        let size = imageSize
        var pixels = [UInt8](repeating: 0, count: size * size * 4)  // RGBA

        guard let ctx = CGContext(
            data: &pixels, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw AestheticsModelError.preprocessingFailed }

        ctx.interpolationQuality = CGInterpolationQuality.high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        let array = try MLMultiArray(
            shape: [1, 3, NSNumber(value: size), NSNumber(value: size)],
            dataType: .float32
        )
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: 3 * size * size)
        let stride = size * size

        for i in 0..<(size * size) {
            ptr[0 * stride + i] = Float(pixels[i * 4 + 0]) / 255.0  // R
            ptr[1 * stride + i] = Float(pixels[i * 4 + 1]) / 255.0  // G
            ptr[2 * stride + i] = Float(pixels[i * 4 + 2]) / 255.0  // B
        }
        return array
    }
}

public enum AestheticsModelError: Error {
    case preprocessingFailed
    case missingOutput(String)
}
