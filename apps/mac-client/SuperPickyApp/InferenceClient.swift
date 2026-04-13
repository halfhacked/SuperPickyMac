import Foundation
import CoreGraphics

enum InferenceError: Error {
    case serverNotReady
    case requestFailed(statusCode: Int)
    case decodingFailed(underlying: Error)
    case imageConversionFailed
}

protocol InferenceClient: Sendable {
    func detect(image: CGImage) async throws -> DetectionResult
    func aesthetics(image: CGImage) async throws -> AestheticsResponse
    func keypoints(image: CGImage) async throws -> KeypointResult
    func flight(image: CGImage) async throws -> FlightResult
    func identify(image: CGImage, topK: Int, temperature: Float,
                  latitude: Double?, longitude: Double?) async throws -> [SpeciesMatch]
    func healthCheck() async throws -> ServerHealth
}
