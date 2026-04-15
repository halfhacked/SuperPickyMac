// CoreMLInferenceClient.swift
//
// Implements InferenceClient using native CoreML model wrappers.
// All five inference endpoints run on-device — no Python server required.
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
    private let logger = Logger(subsystem: "com.superpicky.mac", category: "CoreMLInference")

    // OSEA inference constants (match osea_classifier.py)
    private static let oseaTemperature: Float = 0.9
    private static let oseaGlobalThreshold: Float = 0.90   // 90% confidence required

    init(flightModel: FlightModel, keypointModel: KeypointModel,
         yoloModel: YOLOBirdDetector? = nil,
         oseaModel: OSEAClassifier? = nil,
         speciesDB: SpeciesDatabase? = nil,
         aestheticsModel: AestheticsModel? = nil) {
        self.flightModel = flightModel
        self.keypointModel = keypointModel
        self.yoloModel = yoloModel
        self.oseaModel = oseaModel
        self.speciesDB = speciesDB
        self.aestheticsModel = aestheticsModel
    }

    // MARK: - Native flight inference

    func flight(image: CGImage) async throws -> FlightResult {
        let (isFlying, confidence) = try flightModel.predict(image: image)
        return FlightResult(isFlying: isFlying, confidence: confidence)
    }

    // MARK: - Native keypoint inference

    func keypoints(image: CGImage) async throws -> KeypointResult {
        let result = try keypointModel.predict(image: image)
        return KeypointResult(
            leftEye:  Keypoint(x: result.leftEyeX,  y: result.leftEyeY,  visibility: result.leftEyeVis),
            rightEye: Keypoint(x: result.rightEyeX, y: result.rightEyeY, visibility: result.rightEyeVis),
            beak:     Keypoint(x: result.beakX,     y: result.beakY,     visibility: result.beakVis)
        )
    }

    // MARK: - Native YOLO detection

    func detect(image: CGImage) async throws -> DetectionResult {
        guard let yolo = yoloModel else {
            return DetectionResult(birds: [])
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

    // MARK: - Native species identification

    func identify(filePath: String, topK: Int) async throws -> IdentifyResponse {
        guard let yolo = yoloModel, let osea = oseaModel, let db = speciesDB else {
            return IdentifyResponse(species: [], birds: nil, totalDetected: 0)
        }

        // 1. Load image from file path (CGImageSource handles RAW, JPEG, etc.)
        let url = URL(fileURLWithPath: filePath) as CFURL
        guard let source = CGImageSourceCreateWithURL(url, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            logger.error("OSEA identify: failed to load image at \(filePath)")
            return IdentifyResponse(species: [], birds: nil, totalDetected: 0)
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

    // MARK: - Native aesthetics (CFANet/TOPIQ)

    func aesthetics(image: CGImage) async throws -> AestheticsResponse {
        guard let model = aestheticsModel else {
            return AestheticsResponse(score: 5.0, distribution: [])
        }
        let (mos, distribution) = try model.score(image: image)
        return AestheticsResponse(score: mos, distribution: distribution)
    }

    // MARK: - Health check

    func healthCheck() async throws -> ServerHealth {
        var models = ["flight-coreml", "keypoint-coreml"]
        if yoloModel != nil       { models.append("yolo-coreml") }
        if oseaModel != nil       { models.append("osea-coreml") }
        if aestheticsModel != nil { models.append("aesthetics-coreml") }
        return ServerHealth(
            status: "ready",
            modelsLoaded: models,
            device: "coreml",
            version: "native-phase5"
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

    // MARK: - Factory

    /// Build the native inference client loading all five CoreML models from the app bundle.
    static func make() throws -> CoreMLInferenceClient {
        guard let flightURL = Bundle.main.url(forResource: "FlightDetector", withExtension: "mlmodelc"),
              let keypointURL = Bundle.main.url(forResource: "KeypointDetector", withExtension: "mlmodelc") else {
            throw CoreMLClientError.modelNotFound("FlightDetector or KeypointDetector.mlmodelc not in app bundle")
        }
        let yoloURL       = Bundle.main.url(forResource: "YOLOBirdDetector", withExtension: "mlmodelc")
        let oseaURL       = Bundle.main.url(forResource: "OSEAClassifier", withExtension: "mlmodelc")
        let speciesURL    = Bundle.main.url(forResource: "bird_reference", withExtension: "sqlite")
        let aestheticsURL = Bundle.main.url(forResource: "AestheticsModel", withExtension: "mlmodelc")

        let yolo       = yoloURL.flatMap       { try? YOLOBirdDetector(url: $0) }
        let osea       = oseaURL.flatMap       { try? OSEAClassifier(url: $0) }
        let species    = speciesURL.flatMap    { try? SpeciesDatabase(url: $0) }
        let aesthetics = aestheticsURL.flatMap { try? AestheticsModel(url: $0) }

        return CoreMLInferenceClient(
            flightModel:     try FlightModel(url: flightURL),
            keypointModel:   try KeypointModel(url: keypointURL),
            yoloModel:       yolo,
            oseaModel:       osea,
            speciesDB:       species,
            aestheticsModel: aesthetics
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
