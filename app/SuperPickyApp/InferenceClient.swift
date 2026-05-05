import Foundation
import CoreGraphics

protocol InferenceClient: Sendable {
    func detect(image: CGImage) async throws -> DetectionResult
    func aesthetics(image: CGImage) async throws -> AestheticsResponse
    func keypoints(image: CGImage) async throws -> KeypointResult
    func flight(image: CGImage) async throws -> FlightResult
    /// `preDecodedImage` and `preGPS` let the caller pass work already done
    /// in the pipeline's pre-pass so `identify` doesn't re-open the file.
    /// Any thumbnail ≥ 640×N works for YOLO (it letterboxes to 640).
    func identify(
        filePath: String, topK: Int,
        preDecodedImage: CGImage?, preGPS: (lat: Double, lon: Double)?
    ) async throws -> IdentifyResponse

    /// Warm per-GPS caches for the given cells before the main ML loop,
    /// so concurrent `identify` calls don't serialize on a shared mutex.
    func prewarmGPSCells(_ cells: [(lat: Double, lon: Double)]) async
}

extension InferenceClient {
    func identify(filePath: String, topK: Int) async throws -> IdentifyResponse {
        try await identify(filePath: filePath, topK: topK, preDecodedImage: nil, preGPS: nil)
    }

    func identify(filePath: String, topK: Int, preDecodedImage: CGImage?) async throws -> IdentifyResponse {
        try await identify(filePath: filePath, topK: topK, preDecodedImage: preDecodedImage, preGPS: nil)
    }

    func prewarmGPSCells(_ cells: [(lat: Double, lon: Double)]) async {}
}
