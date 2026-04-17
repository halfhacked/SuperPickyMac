import Foundation
import CoreGraphics

protocol InferenceClient: Sendable {
    func detect(image: CGImage) async throws -> DetectionResult
    func aesthetics(image: CGImage) async throws -> AestheticsResponse
    func keypoints(image: CGImage) async throws -> KeypointResult
    func flight(image: CGImage) async throws -> FlightResult
    /// If `preDecodedImage` is non-nil, YOLO + OSEA consume it directly
    /// and skip the thumbnail decode that `identify` otherwise performs
    /// internally. Caller must pass a CGImage whose coordinate space is
    /// consistent with the original file (same aspect ratio) — any
    /// thumbnail ≥ 640×N is fine since YOLO letterboxes to 640 anyway.
    ///
    /// If `preGPS` is non-nil, the SpeciesFilter reuses it instead of
    /// re-opening the file for a second CGImageSource to read the GPS
    /// IFD. Saves ~5–10 ms of redundant file I/O per photo.
    func identify(
        filePath: String, topK: Int,
        preDecodedImage: CGImage?, preGPS: (lat: Double, lon: Double)?
    ) async throws -> IdentifyResponse
}

extension InferenceClient {
    func identify(filePath: String, topK: Int) async throws -> IdentifyResponse {
        try await identify(filePath: filePath, topK: topK, preDecodedImage: nil, preGPS: nil)
    }

    func identify(filePath: String, topK: Int, preDecodedImage: CGImage?) async throws -> IdentifyResponse {
        try await identify(filePath: filePath, topK: topK, preDecodedImage: preDecodedImage, preGPS: nil)
    }
}
