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
        // ResNet34 was originally pinned to ANE, but once KP + Aesthetics
        // already lived on the GPU and the GPS mutex was gone (9e38fe2),
        // the ANE was the gating engine. Moving OSEA to GPU makes a single
        // OSEA inference ~3 ms (down from ~11 ms) and — together with the
        // Flight move in the same commit — drops the full-folder bench
        // 30 s → 27 s by redistributing work across ANE (YOLO only) and GPU
        // (everything else). See project_perf_baseline_2026-04-16.md.
        configuration.computeUnits = .cpuAndGPU
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
            guard let flipped = Self.flipHorizontal(image: image) else {
                logger.debug("osea.logits preprocess=\(preMs, privacy: .public)ms infer=\(runMs, privacy: .public)ms tta=skip")
                return output1
            }
            let preprocessed2 = try Self.preprocess(image: flipped, isYOLOCropped: isYOLOCropped)
            let output2 = try runModel(inputArray: preprocessed2)
            let merged = zip(output1, output2).map { ($0 + $1) / 2 }
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
        return try normalizeToMLMultiArray(image: cropped)
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

    /// Render a 224×224 CGImage to an NCHW MLMultiArray with ImageNet normalization.
    private static func normalizeToMLMultiArray(image: CGImage) throws -> MLMultiArray {
        let size = cropSize
        var pixels = [UInt8](repeating: 0, count: size * size * 4)  // RGBA

        guard let ctx = CGContext(
            data: &pixels, width: size, height: size,
            bitsPerComponent: 8, bytesPerRow: size * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { throw OSEAError.preprocessingFailed }

        ctx.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))

        let array = try MLMultiArray(shape: [1, 3, NSNumber(value: size), NSNumber(value: size)],
                                     dataType: .float32)
        let ptr = array.dataPointer.bindMemory(to: Float.self, capacity: 3 * size * size)
        let channelStride = size * size
        let mean = InferenceConstants.imageNetMean
        let std = InferenceConstants.imageNetStd

        for i in 0..<(size * size) {
            let r = Float(pixels[i * 4 + 0]) / 255.0
            let g = Float(pixels[i * 4 + 1]) / 255.0
            let b = Float(pixels[i * 4 + 2]) / 255.0
            ptr[0 * channelStride + i] = (r - mean.x) / std.x
            ptr[1 * channelStride + i] = (g - mean.y) / std.y
            ptr[2 * channelStride + i] = (b - mean.z) / std.z
        }
        return array
    }

    /// Horizontal flip of a CGImage (for TTA).
    private static func flipHorizontal(image: CGImage) -> CGImage? {
        guard let ctx = CGContext(
            data: nil, width: image.width, height: image.height,
            bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }

        ctx.translateBy(x: CGFloat(image.width), y: 0)
        ctx.scaleBy(x: -1, y: 1)
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return ctx.makeImage()
    }
}

// MARK: - Errors

public enum OSEAError: Error {
    case preprocessingFailed
    case missingOutput(String)
}
