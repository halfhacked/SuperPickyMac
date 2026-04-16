// InferenceClient implementation backed by native CoreML model wrappers.
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
    private let speciesFilter: SpeciesFilter?
    private let logger = Logger(subsystem: "com.superpicky.mac", category: "CoreMLInference")

    private static let oseaTemperature = InferenceConstants.oseaTemperature
    // Match preen: drop only near-zero noise; the user's birdIdConfidence
    // setting is applied by downstream UI/filters, not here.
    private static let oseaFloorProbability: Float = 0.003  // 0.3%

    init(flightModel: FlightModel, keypointModel: KeypointModel,
         yoloModel: YOLOBirdDetector? = nil,
         oseaModel: OSEAClassifier? = nil,
         speciesDB: SpeciesDatabase? = nil,
         aestheticsModel: AestheticsModel? = nil,
         speciesFilter: SpeciesFilter? = nil) {
        self.flightModel = flightModel
        self.keypointModel = keypointModel
        self.yoloModel = yoloModel
        self.oseaModel = oseaModel
        self.speciesDB = speciesDB
        self.aestheticsModel = aestheticsModel
        self.speciesFilter = speciesFilter
    }

    // MARK: - Native flight inference

    func flight(image: CGImage) async throws -> FlightResult {
        let t = DispatchTime.now()
        let (isFlying, confidence) = try flightModel.predict(image: image)
        logger.debug("flight \(Self.elapsedMs(since: t), privacy: .public)ms flying=\(isFlying, privacy: .public) conf=\(String(format: "%.2f", confidence), privacy: .public)")
        return FlightResult(isFlying: isFlying, confidence: confidence)
    }

    // MARK: - Native keypoint inference

    func keypoints(image: CGImage) async throws -> KeypointResult {
        let t = DispatchTime.now()
        let result = try keypointModel.predict(image: image)
        logger.debug("keypoints \(Self.elapsedMs(since: t), privacy: .public)ms")
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
        let t = DispatchTime.now()
        let dets = try yolo.predict(image: image)
        logger.debug("yolo \(Self.elapsedMs(since: t), privacy: .public)ms birds=\(dets.count, privacy: .public)")
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
        // The body is fully synchronous — ImageIO + CoreML are sync APIs.
        // Wrap in an explicit autoreleasepool so the CGImageSource, CGImage
        // and MLMultiArray temporaries don't pile up on the Swift concurrency
        // thread between photos. Without this, per-photo time on a large
        // run degrades from ~800ms to >4s as the pool grows.
        return try autoreleasepool {
            try identifySync(yolo: yolo, osea: osea, db: db,
                             filePath: filePath, topK: topK)
        }
    }

    private func identifySync(yolo: YOLOBirdDetector, osea: OSEAClassifier,
                              db: SpeciesDatabase, filePath: String, topK: Int) throws -> IdentifyResponse {
        let identifyStart = DispatchTime.now()

        // 1. Load image from file path (CGImageSource handles RAW, JPEG, etc.)
        let decodeStart = DispatchTime.now()
        let fileURL = URL(fileURLWithPath: filePath)
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            logger.error("OSEA identify: failed to load image at \(filePath)")
            return IdentifyResponse(species: [], birds: nil, totalDetected: 0)
        }
        let decodeMs = Self.elapsedMs(since: decodeStart)

        // 1a. Extract GPS from EXIF and resolve an allowed species set.
        //     nil → no filter (either no GPS in file, or the filter
        //     isn't installed, or the region has no data — all fall
        //     through to the existing global-top-1 behavior).
        let allowedIDs: Set<Int>? = {
            guard let filter = speciesFilter,
                  let gps = GPSExtractor.gps(for: fileURL) else { return nil }
            return filter.allowedClassIDs(lat: gps.lat, lon: gps.lon)
        }()

        // 2. YOLO detect
        let yoloStart = DispatchTime.now()
        let detections = try yolo.predict(image: image)
        let yoloMs = Self.elapsedMs(since: yoloStart)

        // 3. For each bird, smart-square crop → OSEA → top species.
        //    Use the same 15%-padding + letterbox semantics as preen so OSEA
        //    sees exactly the crop it was trained on.
        var speciesMatches: [SpeciesMatch] = []
        // Full top-5 from the BEST detection only — used by the parity
        // harness. UI still reads `species` (top-1 per detection).
        var bestTop5: [SpeciesMatch]? = nil
        let oseaStart = DispatchTime.now()

        for det in detections {
            let normalizedBBox = CGRect(
                x: CGFloat(det.x1), y: CGFloat(det.y1),
                width: CGFloat(det.x2 - det.x1), height: CGFloat(det.y2 - det.y1)
            )
            guard let crop = image.smartSquareBirdCrop(bbox: normalizedBBox) else { continue }
            guard crop.width > 10, crop.height > 10 else { continue }

            // 4. OSEA logits with YOLO-crop preprocessing (direct resize, not center crop)
            let logits = try osea.logits(image: crop, isYOLOCropped: true, useTTA: true)
            let validLogits = Array(logits.prefix(OSEAClassifier.numClasses))

            // 5. Apply the regional (GPS/eBird) mask to the logits before
            //    softmax. If every mask-allowed class has probability under
            //    the floor, fall through to the global (unmasked) softmax —
            //    matches Python identify_bird's cascade.
            var usedRegional = false
            let probs: [Float] = {
                if let allowed = allowedIDs, !allowed.isEmpty {
                    let masked: [Float] = validLogits.enumerated().map { idx, v in
                        allowed.contains(idx) ? v : -.infinity
                    }
                    let maskedProbs = Self.softmax(logits: masked, temperature: Self.oseaTemperature)
                    if (maskedProbs.max() ?? 0) >= Self.oseaFloorProbability {
                        usedRegional = true
                        return maskedProbs
                    }
                    // Regional mask killed everything — fall back to global.
                    logger.info("Regional mask wiped OSEA candidates; falling back to global for \(filePath, privacy: .public)")
                }
                return Self.softmax(logits: validLogits, temperature: Self.oseaTemperature)
            }()

            // 6. Confidence threshold gate. Python reference keeps the
            //    top-1 as a genuine identification only when it clears a
            //    cascade threshold: `regionalSpeciesThreshold` (lower) when
            //    the regional mask produced the distribution, otherwise
            //    `globalSpeciesThreshold` (higher).
            let top1Threshold = Self.top1ConfidenceThreshold(usedRegional: usedRegional)

            // 7. Walk the top-5 probabilities; collect ALL DB-resolvable hits
            //    into top5 (for the harness). The top-1 that the UI consumes
            //    is only appended when the highest probability clears
            //    `top1Threshold`; everything below leaves the photo
            //    unidentified instead of confidently mislabelled.
            let topFive = probs.enumerated()
                .sorted { $0.element > $1.element }
                .prefix(max(5, topK))

            var thisCropTop5: [SpeciesMatch] = []
            var top1AppendedForThisCrop = false
            for (classID, prob) in topFive {
                guard prob >= Self.oseaFloorProbability else { break }
                guard let entry = db.lookup(classID: classID) else { continue }
                let match = SpeciesMatch(
                    scientificName: entry.scientificName,
                    commonName: entry.englishName,
                    confidence: prob,
                    cnName: entry.chineseName,
                    pinyin: entry.pinyin,
                    thresholdUsed: usedRegional ? "regional" : "global"
                )
                if !top1AppendedForThisCrop && prob >= top1Threshold {
                    speciesMatches.append(match)
                    top1AppendedForThisCrop = true
                }
                thisCropTop5.append(match)
                if thisCropTop5.count >= 5 { break }
            }
            // Capture top-5 from the first detection that produced any matches
            // (that's the highest-confidence bird YOLO found).
            if bestTop5 == nil && !thisCropTop5.isEmpty {
                bestTop5 = thisCropTop5
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

        let oseaMs = Self.elapsedMs(since: oseaStart)
        logger.debug("identify \(Self.elapsedMs(since: identifyStart), privacy: .public)ms decode=\(decodeMs, privacy: .public)ms yolo=\(yoloMs, privacy: .public)ms osea=\(oseaMs, privacy: .public)ms detections=\(detections.count, privacy: .public) top1=\(speciesMatches.first?.commonName ?? "-", privacy: .public)")
        return IdentifyResponse(
            species: Array(speciesMatches.prefix(topK)),
            birds: birds,
            totalDetected: detections.count,
            top5: bestTop5
        )
    }

    // MARK: - Native aesthetics (CFANet/TOPIQ)

    func aesthetics(image: CGImage) async throws -> AestheticsResponse {
        guard let model = aestheticsModel else {
            return AestheticsResponse(score: 5.0, distribution: [])
        }
        let t = DispatchTime.now()
        let (mos, distribution) = try model.score(image: image)
        logger.debug("aesthetics \(Self.elapsedMs(since: t), privacy: .public)ms mos=\(String(format: "%.2f", mos), privacy: .public)")
        return AestheticsResponse(score: mos, distribution: distribution)
    }

    // MARK: - Threshold helper (exposed for tests)

    /// Map the 0–100 percent thresholds in `InferenceConstants` to the
    /// 0–1 softmax-probability scale the gate actually compares against.
    /// Picks regional (lower) when an eBird/GPS mask produced the
    /// distribution, otherwise global (higher).
    static func top1ConfidenceThreshold(usedRegional: Bool) -> Float {
        let percent = usedRegional
            ? InferenceConstants.regionalSpeciesThreshold
            : InferenceConstants.globalSpeciesThreshold
        return percent / 100
    }

    // MARK: - Timing helper

    private static func elapsedMs(since start: DispatchTime) -> String {
        let ns = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return String(format: "%.0f", Double(ns) / 1_000_000)
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

    /// Build the native inference client from the model cache directory
    /// populated by ModelManager. The directory is typically
    /// ~/Library/Application Support/com.superpicky.mac/ModelCache/
    /// The species SQLite database is bundled inside the app and loaded
    /// from `Bundle.main`, not from the cache directory.
    static func make(modelsDir: URL) throws -> CoreMLInferenceClient {
        let fm = FileManager.default

        func cached(_ name: String, ext: String = "mlmodelc") -> URL? {
            let url = modelsDir.appendingPathComponent("\(name).\(ext)")
            return fm.fileExists(atPath: url.path) ? url : nil
        }

        guard let flightURL   = cached("FlightDetector"),
              let keypointURL = cached("KeypointDetector") else {
            throw CoreMLClientError.modelNotFound(
                "FlightDetector or KeypointDetector not in model cache at \(modelsDir.path). " +
                "Run ModelManager.ensureReady() before creating the client.")
        }

        let yolo       = cached("YOLOBirdDetector").flatMap  { try? YOLOBirdDetector(url: $0) }
        let osea       = cached("OSEAClassifier").flatMap    { try? OSEAClassifier(url: $0) }
        let aesthetics = cached("AestheticsModel").flatMap   { try? AestheticsModel(url: $0) }

        // Species DB is bundled inside SuperPickyInference (small, always needed).
        let species = SpeciesDatabase.bundledURL().flatMap { try? SpeciesDatabase(url: $0) }

        // Species filter: Avonet SQLite is downloaded on first launch via
        // ModelManager into the same modelsDir; the eBird JSONs live in
        // the framework bundle. If avonet.db isn't there yet (fresh
        // install, offline), the filter still loads with a nil Avonet
        // path and falls straight through to the eBird cascade.
        let avonetURL = modelsDir.appendingPathComponent("avonet.db")
        let filter = try? SpeciesFilter(avonetPath: avonetURL)

        return CoreMLInferenceClient(
            flightModel:     try FlightModel(url: flightURL),
            keypointModel:   try KeypointModel(url: keypointURL),
            yoloModel:       yolo,
            oseaModel:       osea,
            speciesDB:       species,
            aestheticsModel: aesthetics,
            speciesFilter:   filter
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
