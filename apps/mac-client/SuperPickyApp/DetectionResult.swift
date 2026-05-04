import Foundation
import CoreGraphics
import SuperPickyInference

struct BirdDetection: Codable, Sendable {
    let bbox: CGRect
    let confidence: Float
    let mask: Data

    enum CodingKeys: String, CodingKey {
        case bbox, confidence, mask
    }

    init(bbox: CGRect, confidence: Float, mask: Data) {
        self.bbox = bbox
        self.confidence = confidence
        self.mask = mask
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bboxArray = try container.decode([Float].self, forKey: .bbox)
        self.bbox = CGRect(
            x: CGFloat(bboxArray[0]),
            y: CGFloat(bboxArray[1]),
            width: CGFloat(bboxArray[2] - bboxArray[0]),
            height: CGFloat(bboxArray[3] - bboxArray[1])
        )
        self.confidence = try container.decode(Float.self, forKey: .confidence)
        let maskBase64 = try container.decode(String.self, forKey: .mask)
        self.mask = Data(base64Encoded: maskBase64) ?? Data()
    }
}

struct DetectionResult: Codable, Sendable {
    let birds: [BirdDetection]
}

struct Keypoint: Codable, Sendable {
    let x: Float
    let y: Float
    let visibility: Float
}

struct KeypointResult: Codable, Sendable {
    let leftEye: Keypoint
    let rightEye: Keypoint
    let beak: Keypoint

    enum CodingKeys: String, CodingKey {
        case leftEye = "left_eye"
        case rightEye = "right_eye"
        case beak
    }

    var allKeypointsHidden: Bool {
        let t = InferenceConstants.keypointVisibilityThreshold
        return leftEye.visibility < t && rightEye.visibility < t && beak.visibility < t
    }

    /// Maximum eye visibility — feeds RatingEngine's visibility-weight
    /// degradation (`max(0.5, min(1.0, vis * 2))`). Mirrors superpicky's
    /// `kp_result.best_eye_visibility` (`keypoint_detector.py:203`).
    var bestEyeVisibility: Float {
        max(leftEye.visibility, rightEye.visibility)
    }
}

struct FlightResult: Codable, Sendable {
    let isFlying: Bool
    let confidence: Float

    enum CodingKeys: String, CodingKey {
        case isFlying = "is_flying"
        case confidence
    }
}

struct AestheticsResponse: Codable, Sendable {
    let score: Float
    let distribution: [Float]
}

struct IdentifyResponse: Codable, Sendable {
    let species: [SpeciesMatch]
    let birds: [BirdDetection]?
    let totalDetected: Int?
    /// Full top-5 species from OSEA (best detection only). Used by the
    /// parity harness; UI code should read `species` (top-1) as before.
    let top5: [SpeciesMatch]?

    enum CodingKeys: String, CodingKey {
        case species, birds, top5
        case totalDetected = "total_detected"
    }

    init(species: [SpeciesMatch],
         birds: [BirdDetection]?,
         totalDetected: Int?,
         top5: [SpeciesMatch]? = nil) {
        self.species = species
        self.birds = birds
        self.totalDetected = totalDetected
        self.top5 = top5
    }
}
