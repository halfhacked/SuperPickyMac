// FlightModel.swift
//
// CoreML wrapper for the EfficientNet-B3 binary flight classifier.
//
// Architecture: EfficientNet-B3 backbone + Dropout(0.2) + Linear(1536, 1) + Sigmoid
// Input:  [1, 3, 384, 384] float32, ImageNet-normalized NCHW
// Output: [1, 1] float32 — sigmoid probability; > 0.5 → is_flying
//
// Source model: ~/projects/SuperPicky/models/superFlier_efficientnet.pth
// Converted via: scripts/convert_flight.py (coremltools 9.0, fp32 precision)
//
// Thread safety: @unchecked Sendable. MLModel is thread-safe per Apple docs.
// preprocess() allocates a fresh MLMultiArray on every call — no shared state.

import CoreML
import CoreGraphics

public final class FlightModel: @unchecked Sendable {

    private let model: MLModel
    public static let imageSize = InferenceConstants.flightInputSize

    // MARK: - Init

    /// Load a compiled FlightDetector.mlmodelc from a given URL.
    public init(url: URL, configuration: MLModelConfiguration = .init()) throws {
        configuration.computeUnits = .all
        self.model = try MLModel(contentsOf: url, configuration: configuration)
    }

    // MARK: - Inference

    /// Returns (isFlying, confidence) for a bird-crop CGImage.
    /// Thread-safe: allocates a fresh MLMultiArray per call.
    public func predict(image: CGImage) throws -> (isFlying: Bool, confidence: Float) {
        return try autoreleasepool {
            let inputArray = try Self.preprocess(image: image)
            let inputFeatures = try MLDictionaryFeatureProvider(dictionary: ["input": inputArray])
            let output = try model.prediction(from: inputFeatures)
            guard let outputValue = output.featureValue(for: "output"),
                  let multiArray = outputValue.multiArrayValue else {
                throw FlightModelError.outputDecodeFailed
            }
            let probability = Float(truncating: multiArray[0])
            return (isFlying: probability > InferenceConstants.flightThreshold,
                    confidence: probability)
        }
    }

    // MARK: - Preprocessing (internal for testing)

    /// Resize → extract RGB → ImageNet normalize → NCHW MLMultiArray.
    /// Allocates a fresh buffer on every call (no shared mutable state).
    ///
    /// Uses bilinear interpolation (`quality: .low`) to match PyTorch's
    /// `transforms.Resize((384, 384))` default, so CoreML sees the same pixel
    /// distribution the classifier was trained on. `.high` (Lanczos) produces
    /// visibly sharper crops and biases the binary flight classifier toward
    /// false positives.
    static func preprocess(image: CGImage) throws -> MLMultiArray {
        let size = imageSize
        guard let resized = image.resized(to: CGSize(width: size, height: size),
                                          quality: .low) else {
            throw FlightModelError.preprocessFailed
        }

        // Render into RGBA byte buffer
        let bytesPerPixel = 4
        var rgba = [UInt8](repeating: 0, count: size * size * bytesPerPixel)
        guard let ctx = CGContext(
            data: &rgba,
            width: size, height: size,
            bitsPerComponent: 8,
            bytesPerRow: size * bytesPerPixel,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw FlightModelError.preprocessFailed
        }
        ctx.draw(resized, in: CGRect(x: 0, y: 0, width: size, height: size))

        // NCHW layout: [1, 3, H, W]
        let inputArray = try MLMultiArray(
            shape: [1, 3, size as NSNumber, size as NSNumber],
            dataType: .float32
        )
        let ptr = inputArray.dataPointer.assumingMemoryBound(to: Float.self)

        let rOffset = 0 * size * size
        let gOffset = 1 * size * size
        let bOffset = 2 * size * size
        let mean = InferenceConstants.imageNetMean
        let std = InferenceConstants.imageNetStd

        for i in 0..<(size * size) {
            let r = Float(rgba[i * bytesPerPixel + 0]) / 255.0
            let g = Float(rgba[i * bytesPerPixel + 1]) / 255.0
            let b = Float(rgba[i * bytesPerPixel + 2]) / 255.0
            ptr[rOffset + i] = (r - mean.x) / std.x
            ptr[gOffset + i] = (g - mean.y) / std.y
            ptr[bOffset + i] = (b - mean.z) / std.z
        }

        return inputArray
    }
}

public enum FlightModelError: Error, LocalizedError {
    case preprocessFailed
    case outputDecodeFailed

    public var errorDescription: String? {
        switch self {
        case .preprocessFailed:  return "FlightModel: image preprocessing failed"
        case .outputDecodeFailed: return "FlightModel: failed to decode CoreML output"
        }
    }
}
