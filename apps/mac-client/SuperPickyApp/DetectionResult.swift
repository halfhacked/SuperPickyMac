import Foundation
import CoreGraphics

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
        leftEye.visibility < 0.3 && rightEye.visibility < 0.3 && beak.visibility < 0.3
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

struct ServerHealth: Codable, Sendable {
    let status: String
    let modelsLoaded: [String]
    let device: String
    let version: String

    enum CodingKeys: String, CodingKey {
        case status
        case modelsLoaded = "models_loaded"
        case device, version
    }
}

struct KeypointResponseWrapper: Codable, Sendable {
    let keypoints: KeypointResult
}

struct AestheticsResponse: Codable, Sendable {
    let score: Float
    let distribution: [Float]
}

struct IdentifyResponse: Codable, Sendable {
    let species: [SpeciesMatch]
    let birds: [BirdDetection]?
    let totalDetected: Int?

    enum CodingKeys: String, CodingKey {
        case species, birds
        case totalDetected = "total_detected"
    }
}
