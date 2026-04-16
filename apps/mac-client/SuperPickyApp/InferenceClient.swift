import Foundation
import CoreGraphics

protocol InferenceClient: Sendable {
    func detect(image: CGImage) async throws -> DetectionResult
    func aesthetics(image: CGImage) async throws -> AestheticsResponse
    func keypoints(image: CGImage) async throws -> KeypointResult
    func flight(image: CGImage) async throws -> FlightResult
    func identify(filePath: String, topK: Int) async throws -> IdentifyResponse
}
