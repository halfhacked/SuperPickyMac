// CoreMLInferenceClient.swift
//
// Implements InferenceClient using CoreML model wrappers.
//
// Phase 1: flight() routes to native FlightModel; all other endpoints
//          delegate to HTTPInferenceClient.
// Phase 2: keypoints() routes to native KeypointModel.
// Phase 3: detect() routes to native YOLOBirdDetector.
// Phase 4: identify() routes to native OSEA + SpeciesDatabase.
// Phase 5: aesthetics() routes to native AestheticsModel (CFANet/TOPIQ).
//
// Lives in SuperPickyApp (not SuperPickyInference) because InferenceClient
// is declared in SuperPickyApp — placing this in SuperPickyInference would
// create a circular dependency.
//
// Thread safety: @unchecked Sendable. MLModel is thread-safe per Apple docs.
// Each model wrapper allocates a fresh MLMultiArray per call (no shared mutable state).

import CoreML
import CoreGraphics
import ImageIO
import Foundation
import SuperPickyInference
import os

final class CoreMLInferenceClient: InferenceClient, @unchecked Sendable {

    private let flightModel: FlightModel
    private let keypointModel: KeypointModel
    private let yoloModel: YOLOBirdDetector?
    private let oseaModel: OSEAClassifier?
    private let speciesDB: SpeciesDatabase?
    private let aestheticsModel: AestheticsModel?
    private let httpFallback: HTTPInferenceClient
    private let logger = Logger(subsystem: "com.superpicky.mac", category: "CoreMLInference")

    // OSEA inference constants (match osea_classifier.py)
    private static let oseaTemperature: Float = 0.9
    private static let oseaGlobalThreshold: Float = 0.90   // 90% confidence required

    init(flightModel: FlightModel, keypointModel: KeypointModel,
         yoloModel: YOLOBirdDetector? = nil,
         oseaModel: OSEAClassifier? = nil,
         speciesDB: SpeciesDatabase? = nil,
         aestheticsModel: AestheticsModel? = nil,
         httpFallback: HTTPInferenceClient) {
        self.flightModel = flightModel
        self.keypointModel = keypointModel
        self.yoloModel = yoloModel
        self.oseaModel = oseaModel
        self.speciesDB = speciesDB
        self.aestheticsModel = aestheticsModel
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

    // MARK: - Phase 4: Native species identification

    func identify(filePath: String, topK: Int) async throws -> IdentifyResponse {
        guard let yolo = yoloModel, let osea = oseaModel, let db = speciesDB else {
            return try await httpFallback.identify(filePath: filePath, topK: topK)
        }

        // 1. Load image from file path (CGImageSource handles RAW, JPEG, etc.)
        let url = URL(fileURLWithPath: filePath) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            logger.error("OSEA identify: failed to load image at \(filePath)")
            return try await httpFallback.identify(filePath: filePath, topK: topK)
        }

        // 2. YOLO detect
        let detections = try yolo.predict(image: image)

        // 3. For each bird, crop → OSEA → top species
        var speciesMatches: [SpeciesMatch] = []
        let imgW = CGFloat(image.width), imgH = CGFloat(image.height)

        for det in detections {
            let cropRect = CGRect(
                x: CGFloat(det.x1) * imgW,
                y: CGFloat(det.y1) * imgH,
                width: CGFloat(det.x2 - det.x1) * imgW,
                height: CGFloat(det.y2 - det.y1) * imgH
            )
            guard cropRect.width > 10, cropRect.height > 10,
                  let crop = image.cropping(to: cropRect) else { continue }

            // 4. OSEA logits (TTA on)
            let logits = try osea.logits(image: crop, useTTA: true)
            let validLogits = Array(logits.prefix(OSEAClassifier.numClasses))

            // 5. Softmax with temperature=0.9
            let probs = Self.softmax(logits: validLogits, temperature: Self.oseaTemperature)

            // 6. Top-k species (global threshold: 90%)
            let topK_probs = probs.enumerated()
                .sorted { $0.element > $1.element }
                .prefix(topK)

            for (classID, prob) in topK_probs {
                guard prob >= Self.oseaGlobalThreshold else { break }
                guard let entry = db.lookup(classID: classID) else { continue }
                speciesMatches.append(SpeciesMatch(
                    scientificName: entry.scientificName,
                    commonName: entry.englishName,
                    confidence: prob,
                    cnName: entry.chineseName,
                    pinyin: nil,
                    thresholdUsed: "global"
                ))
                break  // One species match per bird detection
            }
        }

        let birds = detections.map { d in
            BirdDetection(
                bbox: CGRect(x: CGFloat(d.x1), y: CGFloat(d.y1),
                             width: CGFloat(d.x2 - d.x1), height: CGFloat(d.y2 - d.y1)),
                confidence: d.confidence,
                mask: d.maskData
            )
        }

        return IdentifyResponse(
            species: Array(speciesMatches.prefix(topK)),
            birds: birds,
            totalDetected: detections.count
        )
    }

    // MARK: - Phase 5: Native aesthetics (CFANet/TOPIQ)

    func aesthetics(image: CGImage) async throws -> AestheticsResponse {
        guard let model = aestheticsModel else {
            return try await httpFallback.aesthetics(image: image)
        }
        let (mos, distribution) = try model.score(image: image)
        return AestheticsResponse(score: mos, distribution: distribution)
    }

    func healthCheck() async throws -> ServerHealth {
        let httpHealth = try await httpFallback.healthCheck()
        var native = ["flight-coreml", "keypoint-coreml"]
        if yoloModel != nil       { native.append("yolo-coreml") }
        if oseaModel != nil       { native.append("osea-coreml") }
        if aestheticsModel != nil { native.append("aesthetics-coreml") }
        let phase: String
        if aestheticsModel != nil      { phase = "hybrid-phase5" }
        else if oseaModel != nil       { phase = "hybrid-phase4" }
        else if yoloModel != nil       { phase = "hybrid-phase3" }
        else                           { phase = "hybrid-phase2" }
        return ServerHealth(
            status: httpHealth.status,
            modelsLoaded: native + httpHealth.modelsLoaded,
            device: "coreml+\(httpHealth.device)",
            version: phase
        )
    }

    // MARK: - Softmax helper

    private static func softmax(logits: [Float], temperature: Float) -> [Float] {
        let scaled = logits.map { $0 / temperature }
        let maxVal = scaled.max() ?? 0
        let exps = scaled.map { exp($0 - maxVal) }
        let sumExps = exps.reduce(0, +)
        return sumExps > 0 ? exps.map { $0 / sumExps } : exps
    }

    // MARK: - Factories

    /// Build a Phase 2 client: native flight + keypoints; HTTP fallback for detect/aesthetics/identify.
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

    /// Build a Phase 4 client: native flight + keypoints + YOLO + OSEA; HTTP fallback for aesthetics.
    static func makePhase4(httpFallback: HTTPInferenceClient) throws -> CoreMLInferenceClient {
        guard let flightURL = Bundle.main.url(forResource: "FlightDetector", withExtension: "mlmodelc"),
              let keypointURL = Bundle.main.url(forResource: "KeypointDetector", withExtension: "mlmodelc") else {
            throw CoreMLClientError.modelNotFound("FlightDetector or KeypointDetector.mlmodelc not in app bundle")
        }
        let yoloURL    = Bundle.main.url(forResource: "YOLOBirdDetector", withExtension: "mlmodelc")
        let oseaURL    = Bundle.main.url(forResource: "OSEAClassifier", withExtension: "mlmodelc")
        let speciesURL = Bundle.main.url(forResource: "bird_reference", withExtension: "sqlite")

        let yolo    = yoloURL.flatMap    { try? YOLOBirdDetector(url: $0) }
        let osea    = oseaURL.flatMap    { try? OSEAClassifier(url: $0) }
        let species = speciesURL.flatMap { try? SpeciesDatabase(url: $0) }

        return CoreMLInferenceClient(
            flightModel:   try FlightModel(url: flightURL),
            keypointModel: try KeypointModel(url: keypointURL),
            yoloModel:     yolo,
            oseaModel:     osea,
            speciesDB:     species,
            httpFallback:  httpFallback
        )
    }

    /// Build a Phase 5 client: all five models native; HTTP fallback only for healthCheck.
    static func makePhase5(httpFallback: HTTPInferenceClient) throws -> CoreMLInferenceClient {
        guard let flightURL = Bundle.main.url(forResource: "FlightDetector", withExtension: "mlmodelc"),
              let keypointURL = Bundle.main.url(forResource: "KeypointDetector", withExtension: "mlmodelc") else {
            throw CoreMLClientError.modelNotFound("FlightDetector or KeypointDetector.mlmodelc not in app bundle")
        }
        let yoloURL        = Bundle.main.url(forResource: "YOLOBirdDetector", withExtension: "mlmodelc")
        let oseaURL        = Bundle.main.url(forResource: "OSEAClassifier", withExtension: "mlmodelc")
        let speciesURL     = Bundle.main.url(forResource: "bird_reference", withExtension: "sqlite")
        let aestheticsURL  = Bundle.main.url(forResource: "AestheticsModel", withExtension: "mlmodelc")

        let yolo       = yoloURL.flatMap       { try? YOLOBirdDetector(url: $0) }
        let osea       = oseaURL.flatMap       { try? OSEAClassifier(url: $0) }
        let species    = speciesURL.flatMap    { try? SpeciesDatabase(url: $0) }
        let aesthetics = aestheticsURL.flatMap { try? AestheticsModel(url: $0) }

        return CoreMLInferenceClient(
            flightModel:    try FlightModel(url: flightURL),
            keypointModel:  try KeypointModel(url: keypointURL),
            yoloModel:      yolo,
            oseaModel:      osea,
            speciesDB:      species,
            aestheticsModel: aesthetics,
            httpFallback:   httpFallback
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
