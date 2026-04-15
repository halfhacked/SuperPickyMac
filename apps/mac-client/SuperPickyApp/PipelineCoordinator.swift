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
        burstDetectionEnabled: Bool = true,
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

        let db: ReportDatabase
        do {
            db = try ReportDatabase(folderPath: folder)
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
        }

        // Final burst detection (catches remaining photos)
        if burstDetectionEnabled {
            await runBurstDetection(db: db)
        }
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

    private func processOnePhoto(
        _ photo: inout Photo,
        fileURL: URL,
        ratingConfig: RatingEngine.Config,
        exposureEnabled: Bool,
        exposureThreshold: Float,
    ) async throws {
        // Single call to preen: YOLO detect + species identify (handles image loading, GPS, everything)
        let identifyResult = try await inferenceClient.identify(filePath: fileURL.path, topK: 1)

        guard let bird = identifyResult.birds?.first else {
            photo.starRating = 0
            return
        }
        photo.birdConfidence = bird.confidence

        // Save species
        if let top = identifyResult.species.first {
            photo.speciesScientificName = top.scientificName
            photo.speciesCommonName = top.commonName
            photo.speciesCnName = top.cnName
            photo.speciesPinyin = top.pinyin
            photo.speciesConfidence = top.confidence

        }

        // Load 1280px thumbnail for aesthetics/keypoints/flight (fast, small payload)
        let image = try rawConverter.convert(fileURL: fileURL)

        let cropRect = CGRect(
            x: bird.bbox.origin.x * CGFloat(image.width),
            y: bird.bbox.origin.y * CGFloat(image.height),
            width: bird.bbox.size.width * CGFloat(image.width),
            height: bird.bbox.size.height * CGFloat(image.height)
        )
        guard let birdCrop = image.cropping(to: cropRect) else {
            photo.starRating = 0
            return
        }

        async let aestheticsResponse = inferenceClient.aesthetics(image: image)
        async let keypointResult = inferenceClient.keypoints(image: birdCrop)
        async let flightResult = inferenceClient.flight(image: birdCrop)

        let (aesthetics, keypoints, flight) = try await (aestheticsResponse, keypointResult, flightResult)

        photo.aestheticsScore = aesthetics.score
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

        photo.sharpnessScore = keypoints.bestEyeVisibility * 600

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

        let ratingResult = ratingEngine.calculate(
            detected: true,
            confidence: bird.confidence,
            sharpness: photo.sharpnessScore ?? 0,
            aesthetics: photo.aestheticsScore,
            allKeypointsHidden: keypoints.allKeypointsHidden,
            bestEyeVisibility: keypoints.bestEyeVisibility,
            isOverexposed: photo.exposureStatus == ExposureStatus.overexposed.rawValue,
            isUnderexposed: photo.exposureStatus == ExposureStatus.underexposed.rawValue,
            isFlying: flight.isFlying,
            config: ratingConfig
        )
        photo.starRating = ratingResult.rating
    }
}
