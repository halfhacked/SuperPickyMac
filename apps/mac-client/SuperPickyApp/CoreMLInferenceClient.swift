// CoreMLInferenceClient.swift
//
// Implements InferenceClient using CoreML model wrappers.
//
// Phase 1: flight() routes to native FlightModel; all other endpoints
//          delegate to HTTPInferenceClient.
// Phase 2: keypoints() routes to native KeypointModel.
// Phase 3: detect() routes to native YOLOBirdDetector.
// Phase 4+: identify(), aesthetics() follow in later phases.
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
    private let yoloModel: YOLOBirdDetector?
    private let httpFallback: HTTPInferenceClient
    private let logger = Logger(subsystem: "com.superpicky.mac", category: "CoreMLInference")

    init(flightModel: FlightModel, keypointModel: KeypointModel,
         yoloModel: YOLOBirdDetector? = nil,
         httpFallback: HTTPInferenceClient) {
        self.flightModel = flightModel
        self.keypointModel = keypointModel
        self.yoloModel = yoloModel
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

    // MARK: - Phase 3: Native YOLO detection

    func detect(image: CGImage) async throws -> DetectionResult {
        guard let yolo = yoloModel else {
            return try await httpFallback.detect(image: image)
        }
        let dets = try yolo.predict(image: image)
        let birds = dets.map { d in
            BirdDetection(
                bbox: CGRect(x: CGFloat(d.x1), y: CGFloat(d.y1),
                             width: CGFloat(d.x2 - d.x1),
                             height: CGFloat(d.y2 - d.y1)),
                confidence: d.confidence,
                mask: d.maskData
            )
        }
        return DetectionResult(birds: birds)
    }

    // MARK: - HTTP fallback (replaced phase-by-phase in Phases 4+)

    func aesthetics(image: CGImage) async throws -> AestheticsResponse {
        try await httpFallback.aesthetics(image: image)
    }

    func identify(filePath: String, topK: Int) async throws -> IdentifyResponse {
        try await httpFallback.identify(filePath: filePath, topK: topK)
    }

    func healthCheck() async throws -> ServerHealth {
        let httpHealth = try await httpFallback.healthCheck()
        let nativeModels = ["flight-coreml", "keypoint-coreml"] +
                           (yoloModel != nil ? ["yolo-coreml"] : [])
        return ServerHealth(
            status: httpHealth.status,
            modelsLoaded: nativeModels + httpHealth.modelsLoaded,
            device: "coreml+\(httpHealth.device)",
            version: yoloModel != nil ? "hybrid-phase3" : "hybrid-phase2"
        )
    }

    // MARK: - Factories

    /// Build a Phase 2 client: native flight + keypoints; HTTP fallback for detect/aesthetics/identify.
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

    /// Build a Phase 3 client: native flight + keypoints + YOLO; HTTP fallback for aesthetics/identify.
    /// Falls back to Phase 2 if YOLOBirdDetector.mlmodelc is absent.
    static func makePhase3(httpFallback: HTTPInferenceClient) throws -> CoreMLInferenceClient {
        guard let flightURL = Bundle.main.url(forResource: "FlightDetector", withExtension: "mlmodelc"),
              let keypointURL = Bundle.main.url(forResource: "KeypointDetector", withExtension: "mlmodelc") else {
            throw CoreMLClientError.modelNotFound("FlightDetector or KeypointDetector.mlmodelc not in app bundle")
        }
        let yoloURL = Bundle.main.url(forResource: "YOLOBirdDetector", withExtension: "mlmodelc")
        let yolo = yoloURL.flatMap { try? YOLOBirdDetector(url: $0) }
        return CoreMLInferenceClient(
            flightModel:   try FlightModel(url: flightURL),
            keypointModel: try KeypointModel(url: keypointURL),
            yoloModel:     yolo,
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
