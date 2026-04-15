// KeypointModel.swift
//
// CoreML wrapper for the ResNet50 PartLocalizer keypoint detector.
//
// Architecture: ResNet50 backbone + MLP head → coord_head + vis_head
// Input:  [1, 3, 416, 416] float32, ImageNet-normalized NCHW
// Output: coords [1, 3, 2] — (left_eye xy, right_eye xy, beak xy) all in [0,1]
//         vis    [1, 3]    — (left_eye_vis, right_eye_vis, beak_vis) in [0,1]
//
// Source model: ~/projects/SuperPicky/models/cub200_keypoint_resnet50_slim.pth
// Converted via: scripts/convert_keypoint.py (coremltools 9.0, fp32 precision)
//
// Thread safety: @unchecked Sendable. MLModel is thread-safe per Apple docs.
// preprocess() allocates a fresh MLMultiArray on every call — no shared state.

import CoreML
import CoreGraphics
import Foundation

public final class KeypointModel: @unchecked Sendable {

    private let model: MLModel
    public static let imageSize = 416

    private static let mean: [Float] = [0.485, 0.456, 0.406]
    private static let std:  [Float] = [0.229, 0.224, 0.225]

    // MARK: - Init

    public init(url: URL, configuration: MLModelConfiguration = .init()) throws {
        configuration.computeUnits = .all
        self.model = try MLModel(contentsOf: url, configuration: configuration)
    }

    // MARK: - Result type

    public struct Result: Sendable {
        public let leftEyeX: Float,  leftEyeY: Float,  leftEyeVis: Float
        public let rightEyeX: Float, rightEyeY: Float, rightEyeVis: Float
        public let beakX: Float,     beakY: Float,     beakVis: Float
    }

    // MARK: - Inference

    /// Returns keypoint coordinates and visibilities for a bird-crop CGImage.
    /// All coordinates are in [0, 1] relative to the input crop dimensions.
    /// Thread-safe: allocates a fresh MLMultiArray per call.
    public func predict(image: CGImage) throws -> Result {
        return try autoreleasepool {
            let inputArray = try Self.preprocess(image: image)
            let inputFeatures = try MLDictionaryFeatureProvider(dictionary: ["input": inputArray])
            let output = try model.prediction(from: inputFeatures)

            guard let coordsValue = output.featureValue(for: "coords"),
                  let coordsArray = coordsValue.multiArrayValue,
                  let visValue = output.featureValue(for: "vis"),
                  let visArray = visValue.multiArrayValue else {
                throw KeypointModelError.outputDecodeFailed
            }

            // coords shape: [1, 3, 2] — row-major in memory
            // index 0=left_x, 1=left_y, 2=right_x, 3=right_y, 4=beak_x, 5=beak_y
            let c = coordsArray.dataPointer.assumingMemoryBound(to: Float.self)
            // vis shape: [1, 3] — 0=left_vis, 1=right_vis, 2=beak_vis
            let v = visArray.dataPointer.assumingMemoryBound(to: Float.self)

            return Result(
                leftEyeX:  c[0], leftEyeY:  c[1], leftEyeVis:  v[0],
                rightEyeX: c[2], rightEyeY: c[3], rightEyeVis: v[1],
                beakX:     c[4], beakY:     c[5], beakVis:     v[2]
            )
        }
    }

    // MARK: - Preprocessing

    /// Resize → extract RGB → ImageNet normalize → NCHW MLMultiArray.
    static func preprocess(image: CGImage) throws -> MLMultiArray {
        let size = imageSize
        guard let resized = image.resized(to: CGSize(width: size, height: size)) else {
            throw KeypointModelError.preprocessFailed
        }

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
            throw KeypointModelError.preprocessFailed
        }
        ctx.draw(resized, in: CGRect(x: 0, y: 0, width: size, height: size))

        let inputArray = try MLMultiArray(
            shape: [1, 3, size as NSNumber, size as NSNumber],
            dataType: .float32
        )
        let ptr = inputArray.dataPointer.assumingMemoryBound(to: Float.self)
        let rOff = 0 * size * size
        let gOff = 1 * size * size
        let bOff = 2 * size * size

        for i in 0..<(size * size) {
            let r = Float(rgba[i * bytesPerPixel + 0]) / 255.0
            let g = Float(rgba[i * bytesPerPixel + 1]) / 255.0
            let b = Float(rgba[i * bytesPerPixel + 2]) / 255.0
            ptr[rOff + i] = (r - mean[0]) / std[0]
            ptr[gOff + i] = (g - mean[1]) / std[1]
            ptr[bOff + i] = (b - mean[2]) / std[2]
        }
        return inputArray
    }
}

public enum KeypointModelError: Error, LocalizedError {
    case preprocessFailed, outputDecodeFailed
    public var errorDescription: String? {
        switch self {
        case .preprocessFailed:  return "KeypointModel: image preprocessing failed"
        case .outputDecodeFailed: return "KeypointModel: output decode failed"
        }
    }
}
