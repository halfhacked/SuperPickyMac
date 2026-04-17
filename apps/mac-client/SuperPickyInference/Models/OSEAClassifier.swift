// OSEAClassifier.swift
//
// Wraps the CoreML OSEA ResNet34 bird species classifier.
//
// Architecture: torchvision ResNet34, num_classes=11000 (first 10964 used)
// Two preprocessing paths (match preen's osea_classifier.py exactly):
//   - Full image (CENTER_CROP_TRANSFORM): Resize(256) → CenterCrop(224) →
//     ImageNet normalize. The bird is assumed to be near the center.
//   - YOLO crop (DIRECT_RESIZE_TRANSFORM): Resize(224, 224) bilinear →
//     ImageNet normalize. Direct resize avoids losing any of the already
//     tightly-cropped bird pixels.
// TTA: (original + h-flip logits) / 2  — matches predict_with_tta().
//
// Input:  Any-size CGImage
// Output: [Float] of length 11000 (raw logits, no softmax)
//         Swift callers apply temperature softmax + species masking.
//
// Thread safety: @unchecked Sendable. MLModel is thread-safe per Apple docs.
// Each logits() call allocates a fresh MLMultiArray.

import Accelerate
import CoreML
import CoreGraphics
import Foundation
import os

public final class OSEAClassifier: @unchecked Sendable {

    // MARK: - Constants (match osea_classifier.py)
    public static let resizeSize = 256
    public static let cropSize = InferenceConstants.oseaInputSize
    public static let numClasses = InferenceConstants.oseaNumClasses
    public static let outputDim = 11000

    private static let outputName = "var_602"

    // MARK: - State
    private let model: MLModel
    private let logger = Logger(subsystem: "com.superpicky.mac", category: "OSEAClassifier")

    // MARK: - Init

    public init(url: URL, configuration: MLModelConfiguration = .init()) throws {
        // Pin to ANE — ResNet34 is a native ANE fit, and pinning avoids the
        // CoreML runtime silently routing to GPU when the ANE is busy.
        configuration.computeUnits = .cpuAndNeuralEngine
        self.model = try MLModel(contentsOf: url, configuration: configuration)
    }

    // MARK: - Inference

    /// Return raw logits (no softmax). Callers apply temperature + species masking.
    /// - Parameter image: Input CGImage (any size).
    /// - Parameter isYOLOCropped: `true` when `image` is already a tight bird
    ///   crop from YOLO; uses DIRECT_RESIZE_TRANSFORM (resize straight to
    ///   224×224) to keep every pixel. `false` for full photos (CENTER_CROP).
    /// - Parameter useTTA: If true, average logits with horizontal flip.
    public func logits(image: CGImage,
                       isYOLOCropped: Bool = false,
                       useTTA: Bool = true) throws -> [Float] {
        let preStart = DispatchTime.now()
        let preprocessed = try Self.preprocess(image: image, isYOLOCropped: isYOLOCropped)
        let preMs = Self.elapsedMs(since: preStart)
        let runStart = DispatchTime.now()
        let output1 = try runModel(inputArray: preprocessed)
        let runMs = Self.elapsedMs(since: runStart)

        if useTTA {
            let ttaStart = DispatchTime.now()
            // Flip the already-preprocessed tensor along its W axis instead
            // of re-rendering the source CGImage and re-normalizing it. Saves
            // one CGContext draw + one full normalize pass per photo.
            let flipped = try ImagePreprocessor.horizontalFlipNCHW(preprocessed)
            let output2 = try runModel(inputArray: flipped)
            var merged = [Float](repeating: 0, count: output1.count)
            vDSP_vadd(output1, 1, output2, 1, &merged, 1, vDSP_Length(output1.count))
            var half: Float = 0.5
            vDSP_vsmul(merged, 1, &half, &merged, 1, vDSP_Length(merged.count))
            let ttaMs = Self.elapsedMs(since: ttaStart)
            logger.debug("osea.logits preprocess=\(preMs, privacy: .public)ms infer=\(runMs, privacy: .public)ms tta=\(ttaMs, privacy: .public)ms")
            return merged
        }
        logger.debug("osea.logits preprocess=\(preMs, privacy: .public)ms infer=\(runMs, privacy: .public)ms tta=off")
        return output1
    }

    private static func elapsedMs(since start: DispatchTime) -> Double {
        Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000
    }

    // MARK: - Private

    private func runModel(inputArray: MLMultiArray) throws -> [Float] {
        let input = try MLDictionaryFeatureProvider(dictionary: ["input": inputArray])
        let output = try autoreleasepool { try model.prediction(from: input) }
        guard let outMLA = output.featureValue(for: Self.outputName)?.multiArrayValue else {
            throw OSEAError.missingOutput(Self.outputName)
        }
        let ptr = outMLA.dataPointer.bindMemory(to: Float.self, capacity: Self.outputDim)
        return Array(UnsafeBufferPointer(start: ptr, count: Self.outputDim))
    }

    /// Preprocess into a [1,3,224,224] NCHW float32 MLMultiArray, ImageNet-normalized.
    /// - `isYOLOCropped: true` → direct resize to 224×224 (DIRECT_RESIZE_TRANSFORM).
    /// - `isYOLOCropped: false` → Resize(256) → CenterCrop(224) (CENTER_CROP_TRANSFORM).
    static func preprocess(image: CGImage, isYOLOCropped: Bool = false) throws -> MLMultiArray {
        let cropped: CGImage
        if isYOLOCropped {
            guard let resized = image.resized(to: CGSize(width: cropSize, height: cropSize)) else {
                throw OSEAError.preprocessingFailed
            }
            cropped = resized
        } else {
            let resized = try resizeShorterSide(image: image, targetShortSide: resizeSize)
            cropped = try centerCrop(image: resized, cropSize: cropSize)
        }
        return try ImagePreprocessor.normalizedNCHW(image: cropped, size: cropSize)
    }

    /// Resize the image so the shorter side equals `targetShortSide`, maintaining aspect ratio.
    private static func resizeShorterSide(image: CGImage, targetShortSide: Int) throws -> CGImage {
        let origW = image.width, origH = image.height
        let scale: Double
        if origW < origH {
            scale = Double(targetShortSide) / Double(origW)
        } else {
            scale = Double(targetShortSide) / Double(origH)
        }
        let newW = max(1, Int((Double(origW) * scale).rounded()))
        let newH = max(1, Int((Double(origH) * scale).rounded()))

        guard let ctx = CGContext(
            data: nil, width: newW, height: newH,
            bitsPerComponent: 8, bytesPerRow: newW * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw OSEAError.preprocessingFailed }

        ctx.interpolationQuality = CGInterpolationQuality.high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: newW, height: newH))
        guard let result = ctx.makeImage() else { throw OSEAError.preprocessingFailed }
        return result
    }

    /// Crop `cropSize × cropSize` from the center of the image.
    private static func centerCrop(image: CGImage, cropSize: Int) throws -> CGImage {
        let x = (image.width  - cropSize) / 2
        let y = (image.height - cropSize) / 2
        guard x >= 0, y >= 0,
              let cropped = image.cropping(to: CGRect(x: x, y: y,
                                                       width: cropSize, height: cropSize))
        else { throw OSEAError.preprocessingFailed }
        return cropped
    }

}

// MARK: - Errors

public enum OSEAError: Error {
    case preprocessingFailed
    case missingOutput(String)
}
