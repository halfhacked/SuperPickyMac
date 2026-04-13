import Foundation
import CoreGraphics
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
        writeKeywords: Bool = false,
        keywordFormat: String = "{cn} {en} {pinyin}",
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
                    writeKeywords: writeKeywords,
                    keywordFormat: keywordFormat
                )
            } catch {
                logger.error("Failed to process \(fileURL.lastPathComponent): \(error)")
                photo.starRating = 0
            }

            do {
                try db.save(&photo)
            } catch {
                logger.error("Failed to save photo: \(error)")
            }
            processedCount += 1
            await onPhotoProcessed?()
        }

        // Burst detection — group similar consecutive photos
        do {
            let allPhotos = try db.fetchAllPhotos()
            let burstGroups = burstDetector.detect(photos: allPhotos)
            for group in burstGroups {
                for photo in group.photos {
                    var updated = photo
                    updated.burstGroupID = group.id
                    updated.isBurstBest = (photo.id == group.bestPhotoID)
                    try db.save(&updated)
                }
            }
            if !burstGroups.isEmpty {
                logger.info("Detected \(burstGroups.count) burst groups")
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
        writeKeywords: Bool,
        keywordFormat: String
    ) async throws {
        let image = try rawConverter.convert(fileURL: fileURL)

        let detection = try await inferenceClient.detect(image: image)
        guard let bird = detection.birds.first else {
            photo.starRating = 0
            return
        }
        photo.birdConfidence = bird.confidence

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

        // Sharpness proxy (temporary)
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
        photo.isPick = ratingResult.isPick

        // Bird ID — identify species from cropped region (GPS-boosted when available)
        do {
            let exif = EXIFReader.read(from: fileURL.path)
            // Send full image — preen handles YOLO detection + smart crop internally
            let species = try await inferenceClient.identify(
                image: image, topK: 1, temperature: 0.9,
                latitude: exif?.latitude, longitude: exif?.longitude
            )
            if let top = species.first {
                // Always save species (even below threshold) for display
                photo.speciesScientificName = top.scientificName
                photo.speciesCommonName = top.commonName
                photo.speciesConfidence = top.confidence

                // Only write keywords when species met the confidence threshold
                let aboveThreshold = top.thresholdUsed != "below_threshold"
                if writeKeywords && aboveThreshold {
                    let keywords = KeywordWriter.formatKeywords(
                        template: keywordFormat,
                        en: top.commonName,
                        cn: top.cnName,
                        latin: top.scientificName,
                        pinyin: top.pinyin
                    )
                    if !keywords.isEmpty {
                        do {
                            try KeywordWriter.write(keywords: ["bird"] + keywords, to: fileURL.path)
                        } catch {
                            logger.warning("Keyword writing failed for \(fileURL.lastPathComponent): \(error)")
                        }
                    }
                }
            }
        } catch {
            logger.warning("Species identification failed: \(error)")
        }
    }
}
