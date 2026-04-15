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
    private let httpFallback: HTTPInferenceClient
    private let logger = Logger(subsystem: "com.superpicky.mac", category: "CoreMLInference")

    init(flightModel: FlightModel, httpFallback: HTTPInferenceClient) {
        self.flightModel = flightModel
        self.httpFallback = httpFallback
    }

    // MARK: - Phase 1: Native flight inference

    func flight(image: CGImage) async throws -> FlightResult {
        let (isFlying, confidence) = try flightModel.predict(image: image)
        return FlightResult(isFlying: isFlying, confidence: confidence)
    }

    // MARK: - HTTP fallback (replaced phase-by-phase)

    func detect(image: CGImage) async throws -> DetectionResult {
        try await httpFallback.detect(image: image)
    }

    func aesthetics(image: CGImage) async throws -> AestheticsResponse {
        try await httpFallback.aesthetics(image: image)
    }

    func keypoints(image: CGImage) async throws -> KeypointResult {
        try await httpFallback.keypoints(image: image)
    }

    func identify(filePath: String, topK: Int) async throws -> IdentifyResponse {
        try await httpFallback.identify(filePath: filePath, topK: topK)
    }

    func healthCheck() async throws -> ServerHealth {
        let httpHealth = try await httpFallback.healthCheck()
        return ServerHealth(
            status: httpHealth.status,
            modelsLoaded: ["flight-coreml"] + httpHealth.modelsLoaded,
            device: "coreml+\(httpHealth.device)",
            version: "hybrid-phase1"
        )
    }

    // MARK: - Factory

    /// Build a Phase 1 client: native flight + HTTP fallback for everything else.
    /// Throws `CoreMLClientError.modelNotFound` if FlightDetector.mlmodelc is absent.
    static func makePhase1(httpFallback: HTTPInferenceClient) throws -> CoreMLInferenceClient {
        guard let modelURL = Bundle.main.url(
            forResource: "FlightDetector",
            withExtension: "mlmodelc"
        ) else {
            throw CoreMLClientError.modelNotFound("FlightDetector.mlmodelc not in app bundle")
        }
        let flightModel = try FlightModel(url: modelURL)
        return CoreMLInferenceClient(flightModel: flightModel, httpFallback: httpFallback)
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
