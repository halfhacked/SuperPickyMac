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

    /// Populate SpeciesFilter's Avonet cache concurrently. Six parallel
    /// `identify` calls all cache-missing on the same cell would serialize
    /// on the SQLite FULLMUTEX and stall each call for the full query time.
    func prewarmGPSCells(_ cells: [(lat: Double, lon: Double)]) async {
        guard let filter = speciesFilter, !cells.isEmpty else { return }
        await withTaskGroup(of: Void.self) { group in
            for cell in cells {
                let lat = cell.lat
                let lon = cell.lon
                group.addTask {
                    _ = filter.allowedClassIDs(lat: lat, lon: lon)
                }
            }
            for await _ in group {}
        }
    }

    func identify(
        filePath: String, topK: Int,
        preDecodedImage: CGImage?, preGPS: (lat: Double, lon: Double)?
    ) async throws -> IdentifyResponse {
        guard let yolo = yoloModel, let osea = oseaModel, let db = speciesDB else {
            return IdentifyResponse(species: [], birds: nil, totalDetected: 0)
        }
        let identifyStart = DispatchTime.now()

        // 1. Use the caller-supplied thumbnail when provided (avoids a
        //    redundant ImageIO decode — upstream rawConverter.convert
        //    already produces the same 1280-edge thumbnail). Fall back
        //    to a local decode when it's nil.
        let decodeStart = DispatchTime.now()
        let fileURL = URL(fileURLWithPath: filePath)
        let image: CGImage
        if let preDecodedImage {
            image = preDecodedImage
        } else {
            guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
                logger.error("OSEA identify: failed to open image at \(filePath)")
                return IdentifyResponse(species: [], birds: nil, totalDetected: 0)
            }
            let thumb: CGImage? = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceThumbnailMaxPixelSize: 1280,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
            guard let decoded = thumb ?? CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                logger.error("OSEA identify: failed to decode image at \(filePath)")
                return IdentifyResponse(species: [], birds: nil, totalDetected: 0)
            }
            image = decoded
        }
        let decodeMs = Self.elapsedMs(since: decodeStart)

        // 1a. Build the species-filter cascade [gps → country → global].
        //     Each level carries its own threshold (regional vs global);
        //     the identify step walks them in order and stops at the
        //     first whose top-1 clears the gate — same logic as
        //     `preen/detector.py::detect_and_identify`. A folder without
        //     GPS or with SpeciesFilter disabled gets a single `.global`
        //     level and the full 10 964-class softmax.
        let gpsStart = DispatchTime.now()
        let filterChain: [SpeciesFilterLevel] = {
            guard let filter = speciesFilter else {
                return [SpeciesFilterLevel(kind: .global, classIDs: nil)]
            }
            let gps: (lat: Double, lon: Double)?
            if let preGPS { gps = preGPS }
            else { gps = GPSExtractor.gps(for: fileURL) }
            guard let gps else {
                return [SpeciesFilterLevel(kind: .global, classIDs: nil)]
            }
            return filter.allowedSpeciesChain(lat: gps.lat, lon: gps.lon)
        }()
        let gpsMs = Self.elapsedMs(since: gpsStart)
        logger.debug("identify.gps \(gpsMs, privacy: .public)ms levels=\(filterChain.count, privacy: .public)")

        // 2. YOLO detect — operates on the 1280 thumbnail. Its bbox output
        //    is normalized (0–1); passing the same thumbnail to OSEA below
        //    keeps coordinates consistent.
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
        var cropMs: Double = 0

        for det in detections {
            let normalizedBBox = CGRect(
                x: CGFloat(det.x1), y: CGFloat(det.y1),
                width: CGFloat(det.x2 - det.x1), height: CGFloat(det.y2 - det.y1)
            )
            let cropT = DispatchTime.now()
            guard let crop = image.smartSquareBirdCrop(bbox: normalizedBBox) else { continue }
            cropMs += Double(DispatchTime.now().uptimeNanoseconds - cropT.uptimeNanoseconds) / 1_000_000
            guard crop.width > 10, crop.height > 10 else { continue }

            // 4. OSEA logits with YOLO-crop preprocessing (direct resize, not center crop)
            let logits = try osea.logits(image: crop, isYOLOCropped: true, useTTA: true)
            let validLogits = Array(logits.prefix(OSEAClassifier.numClasses))

            // 5. Walk the full filter cascade, softmaxing at every level
            //    (gps, country, global) regardless of whether an earlier
            //    level already accepted. This lets us surface near-miss
            //    candidates from each tier in the edit panel — a species
            //    that just missed the regional threshold but would have
            //    passed globally still shows up as an option. Top-1
            //    acceptance logic is unchanged: we still stop *tracking
            //    acceptance* at the first level whose max clears its gate.
            var acceptedProbs: [Float]?
            var acceptedLevel: SpeciesFilterLevel.Kind = .global
            var perLevelProbs: [(kind: SpeciesFilterLevel.Kind, probs: [Float])] = []
            perLevelProbs.reserveCapacity(filterChain.count)
            for level in filterChain {
                let probs: [Float]
                if let allowed = level.classIDs, !allowed.isEmpty {
                    let masked: [Float] = validLogits.enumerated().map { idx, v in
                        allowed.contains(idx) ? v : -.infinity
                    }
                    probs = Self.softmax(logits: masked, temperature: Self.oseaTemperature)
                } else {
                    probs = Self.softmax(logits: validLogits, temperature: Self.oseaTemperature)
                }
                perLevelProbs.append((level.kind, probs))
                if acceptedProbs == nil {
                    let threshold = Self.top1ConfidenceThreshold(level: level.kind)
                    if (probs.max() ?? 0) >= threshold {
                        acceptedProbs = probs
                        acceptedLevel = level.kind
                    }
                }
            }

            // 6a. Primary species (top-1) still comes from the accepted
            //     level only. If no level cleared, the photo stays
            //     unidentified — nothing is appended to `speciesMatches`.
            if let accepted = acceptedProbs,
               let top1 = accepted.enumerated().max(by: { $0.element < $1.element }),
               top1.element >= Self.oseaFloorProbability,
               let entry = db.lookup(classID: top1.offset) {
                speciesMatches.append(SpeciesMatch(
                    scientificName: entry.scientificName,
                    commonName: entry.englishName,
                    confidence: top1.element,
                    cnName: entry.chineseName,
                    pinyin: entry.pinyin,
                    thresholdUsed: acceptedLevel.rawValue,
                    ebirdCode: entry.ebirdCode
                ))
            }

            // 6b. Candidate union across every level. For each (level, probs)
            //     pair pull the top-5 above floor, then merge into a single
            //     by-classID map keeping the highest-confidence entry (with
            //     that level recorded as `thresholdUsed`). Cap final output
            //     at 10 so the edit panel UI stays digestible.
            var byClassID: [Int: SpeciesMatch] = [:]
            for (kind, probs) in perLevelProbs {
                let top = probs.enumerated()
                    .sorted { $0.element > $1.element }
                    .prefix(5)
                for (classID, prob) in top {
                    guard prob >= Self.oseaFloorProbability else { break }
                    guard let entry = db.lookup(classID: classID) else { continue }
                    let newMatch = SpeciesMatch(
                        scientificName: entry.scientificName,
                        commonName: entry.englishName,
                        confidence: prob,
                        cnName: entry.chineseName,
                        pinyin: entry.pinyin,
                        thresholdUsed: kind.rawValue,
                        ebirdCode: entry.ebirdCode
                    )
                    if let existing = byClassID[classID] {
                        if prob > existing.confidence {
                            byClassID[classID] = newMatch
                        }
                    } else {
                        byClassID[classID] = newMatch
                    }
                }
            }
            let thisCropCandidates = byClassID.values
                .sorted { $0.confidence > $1.confidence }
                .prefix(10)
            if bestTop5 == nil && !thisCropCandidates.isEmpty {
                bestTop5 = Array(thisCropCandidates)
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
        logger.debug("identify \(Self.elapsedMs(since: identifyStart), privacy: .public)ms decode=\(decodeMs, privacy: .public)ms yolo=\(yoloMs, privacy: .public)ms osea=\(oseaMs, privacy: .public)ms crop=\(String(format: "%.0f", cropMs), privacy: .public)ms detections=\(detections.count, privacy: .public) top1=\(speciesMatches.first?.commonName ?? "-", privacy: .public)")
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

    /// Maps the percent threshold in `InferenceConstants` to the 0–1
    /// softmax-probability scale the gate compares against. GPS-masked
    /// and country-masked levels both use the regional threshold; the
    /// unfiltered global level uses the higher global threshold.
    static func top1ConfidenceThreshold(level: SpeciesFilterLevel.Kind) -> Float {
        let percent: Float
        switch level {
        case .gps, .country: percent = InferenceConstants.regionalSpeciesThreshold
        case .global:        percent = InferenceConstants.globalSpeciesThreshold
        }
        return percent / 100
    }

    /// Back-compat shim used by existing tests; the `usedRegional` flag
    /// maps to the regional threshold when true, global when false.
    static func top1ConfidenceThreshold(usedRegional: Bool) -> Float {
        top1ConfidenceThreshold(level: usedRegional ? .gps : .global)
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

        // Species filter: Avonet SQLite is downloaded on first launch via
        // ModelManager into the same modelsDir; the eBird JSONs live in
        // the framework bundle. If avonet.db isn't there yet (fresh
        // install, offline), the filter still loads with a nil Avonet
        // path and falls straight through to the eBird cascade.
        // Built first so the eBird ↔ class-id mapping can feed the
        // species database below.
        let avonetURL = modelsDir.appendingPathComponent("avonet.db")
        let filter = try? SpeciesFilter(avonetPath: avonetURL)

        // Species DB is bundled inside SuperPickyInference (small, always
        // needed). Annotate each row with its eBird code from the filter
        // so UI code can use it as a stable identifier.
        let ebirdByClassID = filter?.ebirdCodeByClassID ?? [:]
        let species = SpeciesDatabase.bundledURL().flatMap {
            try? SpeciesDatabase(url: $0, ebirdByClassID: ebirdByClassID)
        }

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
