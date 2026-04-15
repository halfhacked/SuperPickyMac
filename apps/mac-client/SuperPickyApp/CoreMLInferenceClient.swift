// CoreMLInferenceClient.swift
//
// Implements InferenceClient using CoreML model wrappers.
//
// Phase 1: flight() routes to native FlightModel; all other endpoints
//          delegate to HTTPInferenceClient.
// Phase 2: keypoints() will route to native KeypointModel.
// Phase 3+: detect(), identify(), aesthetics() follow in later phases.
//
// Lives in SuperPickyApp (not SuperPickyInference) because InferenceClient
// is declared in SuperPickyApp — placing this in SuperPickyInference would
// create a circular dependency.
//
// Thread safety: @unchecked Sendable. MLModel is thread-safe per Apple docs.
// Each model wrapper allocates a fresh MLMultiArray per call (no shared mutable state).

import CoreML
import CoreGraphics
import Foundation
import SuperPickyInference
import os

final class CoreMLInferenceClient: InferenceClient, @unchecked Sendable {

    private let flightModel: FlightModel
    private let keypointModel: KeypointModel
    private let httpFallback: HTTPInferenceClient
    private let logger = Logger(subsystem: "com.superpicky.mac", category: "CoreMLInference")

    init(flightModel: FlightModel, keypointModel: KeypointModel, httpFallback: HTTPInferenceClient) {
        self.flightModel = flightModel
        self.keypointModel = keypointModel
        self.httpFallback = httpFallback
    }

    // MARK: - Phase 1: Native flight inference

    func flight(image: CGImage) async throws -> FlightResult {
        let (isFlying, confidence) = try flightModel.predict(image: image)
        return FlightResult(isFlying: isFlying, confidence: confidence)
    }

    // MARK: - Phase 2: Native keypoint inference

    func keypoints(image: CGImage) async throws -> KeypointResult {
        let result = try keypointModel.predict(image: image)
        return KeypointResult(
            leftEye:  Keypoint(x: result.leftEyeX,  y: result.leftEyeY,  visibility: result.leftEyeVis),
            rightEye: Keypoint(x: result.rightEyeX, y: result.rightEyeY, visibility: result.rightEyeVis),
            beak:     Keypoint(x: result.beakX,     y: result.beakY,     visibility: result.beakVis)
        )
    }

    // MARK: - HTTP fallback (replaced phase-by-phase in Phases 3+)

    func detect(image: CGImage) async throws -> DetectionResult {
        try await httpFallback.detect(image: image)
    }

    func aesthetics(image: CGImage) async throws -> AestheticsResponse {
        try await httpFallback.aesthetics(image: image)
    }

    func identify(filePath: String, topK: Int) async throws -> IdentifyResponse {
        try await httpFallback.identify(filePath: filePath, topK: topK)
    }

    func healthCheck() async throws -> ServerHealth {
        let httpHealth = try await httpFallback.healthCheck()
        return ServerHealth(
            status: httpHealth.status,
            modelsLoaded: ["flight-coreml", "keypoint-coreml"] + httpHealth.modelsLoaded,
            device: "coreml+\(httpHealth.device)",
            version: "hybrid-phase2"
        )
    }

    // MARK: - Factory

    /// Build a Phase 2 client: native flight + keypoints; HTTP fallback for the rest.
    /// Throws `CoreMLClientError.modelNotFound` if either model file is absent.
    static func makePhase2(httpFallback: HTTPInferenceClient) throws -> CoreMLInferenceClient {
        guard let flightURL = Bundle.main.url(forResource: "FlightDetector", withExtension: "mlmodelc"),
              let keypointURL = Bundle.main.url(forResource: "KeypointDetector", withExtension: "mlmodelc") else {
            throw CoreMLClientError.modelNotFound("FlightDetector or KeypointDetector.mlmodelc not in app bundle")
        }
        return CoreMLInferenceClient(
            flightModel:   try FlightModel(url: flightURL),
            keypointModel: try KeypointModel(url: keypointURL),
            httpFallback:  httpFallback
        )
    }
}

enum CoreMLClientError: Error, LocalizedError {
    case modelNotFound(String)

    var errorDescription: String? {
        switch self {
        case .modelNotFound(let name):
            return "CoreML model not found: \(name)"
        }
    }
}
