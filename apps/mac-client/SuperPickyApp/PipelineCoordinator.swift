import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os

@Observable
final class PipelineCoordinator {
    private let inferenceClient: InferenceClient
    private let ratingEngine = RatingEngine()
    private let exposureDetector = ExposureDetector()
    private let burstDetector = BurstDetector()
    private let rawConverter = RAWConverter()
    private let scanner = DirectoryScanner()
    private let logger = Logger(subsystem: "com.superpicky.mac", category: "Pipeline")

    var totalCount = 0
    var processedCount = 0
    var currentFilename = ""
    var isProcessing = false

    init(inferenceClient: InferenceClient) {
        self.inferenceClient = inferenceClient
    }

    func process(
        folder: URL,
        ratingConfig: RatingEngine.Config,
        exposureEnabled: Bool,
        exposureThreshold: Float,
        flightDetectionEnabled: Bool = true,
        burstDetectionEnabled: Bool = true,
        pickedTopPercentage: Int = PickedFlagCalculator.defaultTopPercentage,
        databaseName: String = ".report.db",
        onPhotoProcessed: (@Sendable () async -> Void)? = nil
    ) async {
        isProcessing = true
        defer { isProcessing = false }

        let files: [URL]
        do {
            files = try scanner.scan(folder: folder)
        } catch {
            logger.error("Failed to scan folder: \(error)")
            return
        }
        totalCount = files.count
        processedCount = 0

        // Memory budget note: Phase 2+ model wrappers add synchronous
        // `autoreleasepool { ... }` blocks inside their predict() methods to
        // release MLMultiArray/MLFeatureProvider temporaries at each photo
        // boundary. Here in Phase 0 we cycle the runtime loop once per
        // iteration via Task.yield() below so ARC gets a scheduled chance
        // to release temporaries between photos even before the model
        // wrappers exist. See docs/superpowers/specs/2026-04-15-native-inference-rewrite-design.md
        // Section 5 "Memory budget".

        let db: ReportDatabase
        do {
            db = try ReportDatabase(folderPath: folder, name: databaseName)
        } catch {
            logger.error("Failed to open database: \(error)")
            return
        }

        for fileURL in files {
            if Task.isCancelled { break }

            currentFilename = fileURL.lastPathComponent

            // Skip already-processed photos (preserve manual ratings)
            if let existing = try? db.fetchByFilePath(fileURL.path) {
                if existing.isManualRating {
                    logger.info("Skipping \(fileURL.lastPathComponent): manual rating preserved")
                }
                processedCount += 1
                await onPhotoProcessed?()
                continue
            }

            var photo = Photo(
                filename: fileURL.lastPathComponent,
                filePath: fileURL.path,
                folderPath: folder.path
            )

            do {
                try await processOnePhoto(
                    &photo,
                    fileURL: fileURL,
                    ratingConfig: ratingConfig,
                    exposureEnabled: exposureEnabled,
                    exposureThreshold: exposureThreshold,
                    flightDetectionEnabled: flightDetectionEnabled,
                )
            } catch {
                logger.error("Failed to process \(fileURL.lastPathComponent): \(error)")
                photo.starRating = 0
            }

            do {
                try db.save(&photo)
                try? XMPWriter.write(photo: photo)
            } catch {
                logger.error("Failed to save photo: \(error)")
            }
            processedCount += 1

            // Run burst detection every 10 photos for incremental updates
            if burstDetectionEnabled && processedCount % 10 == 0 {
                await runBurstDetection(db: db)
            }

            await onPhotoProcessed?()

            // Yield once per iteration so ARC can release any temporaries
            // allocated by processOnePhoto before the next photo starts.
            // See memory-budget note above.
            await Task.yield()
        }

        // Final burst detection (catches remaining photos)
        if burstDetectionEnabled {
            await runBurstDetection(db: db)
        }

        // Picked flag calculation (intersection of top aesthetics & sharpness among 5-star)
        await runPickedFlagCalculation(db: db, topPercentage: pickedTopPercentage)
    }

    private func runBurstDetection(db: ReportDatabase) async {
        do {
            let allPhotos = try db.fetchAllPhotos()
            let detector = burstDetector  // capture value, not self
            // Move blocking Vision CPU work off the cooperative thread pool
            let burstGroups = await Task.detached(priority: .utility) {
                detector.detect(photos: allPhotos)
            }.value
            for group in burstGroups {
                for photo in group.photos {
                    var updated = photo
                    updated.burstGroupID = group.id
                    updated.isBurstBest = (photo.id == group.bestPhotoID)
                    try db.save(&updated)
                }
            }
        } catch {
            logger.error("Burst detection failed: \(error)")
        }
    }

    private func runPickedFlagCalculation(db: ReportDatabase, topPercentage: Int) async {
        do {
            let allPhotos = try db.fetchAllPhotos()
            let pickedIDs = PickedFlagCalculator.calculatePickedIDs(
                photos: allPhotos, topPercentage: topPercentage
            )

            if pickedIDs.isEmpty {
                logger.info("No picked photos (no 5-star photos or empty intersection)")
                return
            }

            logger.info("Picked flag: \(pickedIDs.count) photos selected")

            // Clear old picked flags and set new ones
            for photo in allPhotos {
                let shouldBePicked = pickedIDs.contains(photo.id)
                // Only update if flag needs to change (avoid unnecessary DB writes)
                if photo.isPick != shouldBePicked {
                    var updated = photo
                    updated.isPick = shouldBePicked
                    try db.save(&updated)
                    try? XMPWriter.write(photo: updated)
                }
            }
        } catch {
            logger.error("Picked flag calculation failed: \(error)")
        }
    }

    private func processOnePhoto(
        _ photo: inout Photo,
        fileURL: URL,
        ratingConfig: RatingEngine.Config,
        exposureEnabled: Bool,
        exposureThreshold: Float,
        flightDetectionEnabled: Bool,
    ) async throws {
        // Single call: YOLO detect + OSEA species identify (with GPS/eBird
        // filtering if the filter is loaded). We ask for top-5 so the parity
        // harness can compare full top-5 overlap, not just top-1.
        let identifyResult = try await inferenceClient.identify(filePath: fileURL.path, topK: 5)

        guard let bird = identifyResult.birds?.first else {
            photo.starRating = 0
            return
        }
        photo.birdConfidence = bird.confidence
        // Persist YOLO bbox (normalized [x1, y1, x2, y2]) so the parity
        // harness can compute IoU against the Python reference.
        photo.birdBboxJSON = Self.encodeJSON([
            Float(bird.bbox.minX), Float(bird.bbox.minY),
            Float(bird.bbox.maxX), Float(bird.bbox.maxY),
        ])

        // Save species
        if let top = identifyResult.species.first {
            photo.speciesScientificName = top.scientificName
            photo.speciesCommonName = top.commonName
            photo.speciesCnName = top.cnName
            photo.speciesPinyin = top.pinyin
            photo.speciesConfidence = top.confidence
        }
        // Persist the full top-5 for parity. UI never reads this.
        if let top5 = identifyResult.top5 {
            photo.speciesTop5JSON = Self.encodeJSON(top5)
        }

        // Load 1280px thumbnail for aesthetics/keypoints/flight (fast, small payload)
        let image = try rawConverter.convert(fileURL: fileURL)

        // Smart square crop with 15% padding + letterboxing, matching preen's
        // YOLOBirdDetector.detect_and_crop_bird. The flight / keypoint / OSEA
        // models were all trained on square crops with ~15 % context; feeding
        // a raw rectangular YOLO bbox stretched to their input size causes
        // severe false positives in the flight classifier.
        guard let birdCrop = image.smartSquareBirdCrop(bbox: bird.bbox) else {
            photo.starRating = 0
            return
        }

        async let aestheticsResponse = inferenceClient.aesthetics(image: image)
        async let keypointResult = inferenceClient.keypoints(image: birdCrop)
        async let flightResult = flightDetectionEnabled
            ? inferenceClient.flight(image: birdCrop)
            : FlightResult(isFlying: false, confidence: 0)

        let (aesthetics, keypoints, flight) = try await (aestheticsResponse, keypointResult, flightResult)

        photo.aestheticsScore = aesthetics.score
        // Persist full 10-bin AVA distribution for the parity harness.
        if !aesthetics.distribution.isEmpty {
            photo.aestheticsDistributionJSON = Self.encodeJSON(aesthetics.distribution)
        }
        photo.leftEyeX = keypoints.leftEye.x
        photo.leftEyeY = keypoints.leftEye.y
        photo.leftEyeVis = keypoints.leftEye.visibility
        photo.rightEyeX = keypoints.rightEye.x
        photo.rightEyeY = keypoints.rightEye.y
        photo.rightEyeVis = keypoints.rightEye.visibility
        photo.beakX = keypoints.beak.x
        photo.beakY = keypoints.beak.y
        photo.beakVis = keypoints.beak.visibility
        photo.isFlying = flight.isFlying
        photo.flightConfidence = flight.confidence

        // Head-region sharpness (circular mask around eye, matches superpicky)
        let headSharpness = HeadSharpness.score(
            birdCrop: birdCrop,
            leftEyeX: keypoints.leftEye.x, leftEyeY: keypoints.leftEye.y,
            leftEyeVis: keypoints.leftEye.visibility,
            rightEyeX: keypoints.rightEye.x, rightEyeY: keypoints.rightEye.y,
            rightEyeVis: keypoints.rightEye.visibility,
            beakX: keypoints.beak.x, beakY: keypoints.beak.y,
            beakVis: keypoints.beak.visibility
        ) ?? TenengradSharpness.score(image: birdCrop) // fallback to full-crop

        // ISO normalization: high ISO reduces sharpness (noise inflates gradients)
        let exif = EXIFReader.read(from: fileURL.path)
        let isoFactor = Self.isoSharpnessFactor(iso: exif?.iso)
        photo.sharpnessScore = headSharpness * isoFactor

        if exposureEnabled {
            let exposure = exposureDetector.detect(image: image, threshold: exposureThreshold)
            if exposure.isOverexposed {
                photo.exposureStatus = ExposureStatus.overexposed.rawValue
            } else if exposure.isUnderexposed {
                photo.exposureStatus = ExposureStatus.underexposed.rawValue
            } else {
                photo.exposureStatus = ExposureStatus.normal.rawValue
            }
        }

        // Focus point weighting: detect where camera focused relative to bird
        let bestEye: (x: Float, y: Float) = {
            let lv = keypoints.leftEye.visibility
            let rv = keypoints.rightEye.visibility
            if lv >= rv { return (keypoints.leftEye.x, keypoints.leftEye.y) }
            return (keypoints.rightEye.x, keypoints.rightEye.y)
        }()

        // Seg mask: YOLO outputs a square mask at model resolution (e.g. 160x160).
        // Infer dimensions from data size (sqrt of byte count for square masks).
        let segMask: Data? = bird.mask.isEmpty ? nil : bird.mask
        let maskSide = segMask != nil ? Int(sqrt(Double(bird.mask.count))) : 0
        let maskWidth = (maskSide * maskSide == bird.mask.count) ? maskSide : 0
        let maskHeight = maskWidth  // Square mask

        let focusWeights = FocusPointDetector.computeWeights(
            filePath: fileURL.path,
            birdBbox: bird.bbox,
            eyeCenter: bestEye,
            headRadiusFraction: HeadSharpness.noBeakRadiusRatio,
            segMask: segMask,
            maskWidth: maskWidth,
            maskHeight: maskHeight
        )

        let ratingResult = ratingEngine.calculate(
            detected: true,
            confidence: bird.confidence,
            sharpness: photo.sharpnessScore ?? 0,
            aesthetics: photo.aestheticsScore,
            allKeypointsHidden: keypoints.allKeypointsHidden,
            isOverexposed: photo.exposureStatus == ExposureStatus.overexposed.rawValue,
            isUnderexposed: photo.exposureStatus == ExposureStatus.underexposed.rawValue,
            focusSharpnessWeight: focusWeights.sharpness,
            focusAestheticsWeight: focusWeights.aesthetics,
            isFlying: flight.isFlying,
            config: ratingConfig
        )
        photo.starRating = ratingResult.rating
    }

    /// ISO sharpness normalization: 5% penalty per ISO doubling above 800.
    /// ISO ≤ 800 → 1.0, ISO 1600 → 0.95, ISO 3200 → 0.90, ISO 6400 → 0.85, floor at 0.5.
    private static let isoBase: Float = 800
    private static let isoPenaltyFactor: Float = 0.05
    private static let isoMinFactor: Float = 0.5

    static func isoSharpnessFactor(iso: Int?) -> Float {
        guard let iso, iso > Int(isoBase) else { return 1.0 }
        let penalty = isoPenaltyFactor * log2(Float(iso) / isoBase)
        return max(isoMinFactor, 1.0 - penalty)
    }

    /// JSON-encode a value to a UTF-8 string for storage in the
    /// parity-harness text columns. Returns nil on encoding failure.
    static func encodeJSON<T: Encodable>(_ value: T) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]  // deterministic for diffing
        guard let data = try? encoder.encode(value),
              let s = String(data: data, encoding: .utf8) else { return nil }
        return s
    }
}
