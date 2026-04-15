// OSEAClassifier.swift
//
// Wraps the CoreML OSEA ResNet34 bird species classifier.
//
// Architecture: torchvision ResNet34, num_classes=11000 (first 10964 used)
// Preprocessing: Resize(256) → CenterCrop(224) → ImageNet normalize
// TTA: (original + h-flip logits) / 2  — matches osea_classifier.py predict_with_tta()
//
// Input:  Any-size CGImage (bird crop from YOLO detection)
// Output: [Float] of length 11000 (raw logits, no softmax)
//         Swift callers apply temperature softmax + species masking
//
// Thread safety: @unchecked Sendable. MLModel is thread-safe per Apple docs.
// Each logits() call allocates a fresh MLMultiArray.

import CoreML
import CoreGraphics
import Foundation
import os

public final class OSEAClassifier: @unchecked Sendable {

    // MARK: - Constants (match osea_classifier.py)
    public static let resizeSize = 256       // Resize shorter side to this
    public static let cropSize = 224         // Center crop to this
    public static let numClasses = 10964     // Valid OSEA classes (out of 11000 output)
    public static let outputDim = 11000      // Full model output dimension

    // ImageNet normalization (matches osea_classifier.py CENTER_CROP_TRANSFORM)
    private static let mean: [Float] = [0.485, 0.456, 0.406]
    private static let std:  [Float] = [0.229, 0.224, 0.225]

    private static let outputName = "var_602"

    // MARK: - State
    private let model: MLModel
    private let logger = Logger(subsystem: "com.superpicky.mac", category: "OSEAClassifier")

    // MARK: - Init

    public init(url: URL, configuration: MLModelConfiguration = .init()) throws {
        configuration.computeUnits = .all
        self.model = try MLModel(contentsOf: url, configuration: configuration)
    }

    // MARK: - Inference

    /// Return raw logits (no softmax). Callers apply temperature + species masking.
    /// - Parameter image: Bird crop CGImage (any size — will be resized/cropped)
    /// - Parameter useTTA: If true, average logits with horizontal flip (matches Python TTA)
    public func logits(image: CGImage, useTTA: Bool = true) throws -> [Float] {
        let preprocessed = try Self.preprocess(image: image)
        let output1 = try runModel(inputArray: preprocessed)

        if useTTA {
            guard let flipped = Self.flipHorizontal(image: image) else {
                return output1
            }
            let preprocessed2 = try Self.preprocess(image: flipped)
            let output2 = try runModel(inputArray: preprocessed2)
            return zip(output1, output2).map { ($0 + $1) / 2 }
        }
        return output1
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

    /// Resize(256) → CenterCrop(224) → ImageNet normalize → MLMultiArray [1,3,224,224]
    static func preprocess(image: CGImage) throws -> MLMultiArray {
        // Step 1: Resize shorter side to 256
        let resized = try resizeShorterSide(image: image, targetShortSide: resizeSize)

        // Step 2: Center crop to 224×224
        let cropped = try centerCrop(image: resized, cropSize: cropSize)

        // Step 3: ImageNet normalize → MLMultiArray [1,3,224,224]
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

        for i in 0..<(size * size) {
            let r = Float(pixels[i * 4 + 0]) / 255.0
            let g = Float(pixels[i * 4 + 1]) / 255.0
            let b = Float(pixels[i * 4 + 2]) / 255.0
            ptr[0 * channelStride + i] = (r - mean[0]) / std[0]
            ptr[1 * channelStride + i] = (g - mean[1]) / std[1]
            ptr[2 * channelStride + i] = (b - mean[2]) / std[2]
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
