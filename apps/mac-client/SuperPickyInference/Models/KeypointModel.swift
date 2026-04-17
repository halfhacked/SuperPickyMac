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
    public static let imageSize = InferenceConstants.keypointInputSize

    // MARK: - Init

    public init(url: URL, configuration: MLModelConfiguration = .init()) throws {
        configuration.computeUnits = .cpuAndNeuralEngine
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
        do {
            return try ImagePreprocessor.normalizedNCHW(image: image, size: imageSize)
        } catch {
            throw KeypointModelError.preprocessFailed
        }
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
