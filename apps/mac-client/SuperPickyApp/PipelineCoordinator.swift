import Foundation
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
import os

@Observable
final class PipelineCoordinator: @unchecked Sendable {
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

    /// Max photos whose ML work (decode + YOLO + OSEA + aesthetics/keypoints/
    /// flight) may be in flight simultaneously. Compute-unit split pins
    /// Aesthetics to GPU and OSEA/Keypoint/Flight to ANE so several photos'
    /// work can truly overlap across engines. Post-processing (DB, burst
    /// state, UI callback) still runs strictly in timestamp order.
    private static let maxConcurrentMLWork = 3

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
        burstFps: Int = 10,
        burstMinCount: Int = 2,
        burstHashTolerance: Int = 12,
        pickedTopPercentage: Int = PickedFlagCalculator.defaultTopPercentage,
        databaseName: String = ".report.db",
        onPhotoProcessed: (@Sendable (Photo?) async -> Void)? = nil
    ) async {
        isProcessing = true
        defer { isProcessing = false }

        // Build a local BurstDetector with the user-configured thresholds.
        // Default init on the class-level `burstDetector` only supplied
        // hardcoded 500 ms / min 2 / hash 12; wiring it here lets the
        // Advanced Settings sliders (burstFps / burstMinCount /
        // burstHashTolerance) actually influence processing.
        //
        // Time threshold derives from the configured burst FPS plus a 1.5×
        // tolerance — at 20 fps this gives 75 ms (tight), at 10 fps this
        // gives 150 ms, and a floor of 50 ms prevents divide-by-zero.
        let burstTimeThresholdMs = max(50.0, 1000.0 / Double(max(1, burstFps)) * 1.5)
        let burstDetector = BurstDetector(
            timeThresholdMs: burstTimeThresholdMs,
            minBurstCount: burstMinCount,
            similarityThreshold: Float(burstHashTolerance)
        )

        let scannedFiles: [URL]
        do {
            scannedFiles = try scanner.scan(folder: folder)
        } catch {
            logger.error("Failed to scan folder: \(error)")
            return
        }

        // Sort files by EXIF timestamp so burst detection can run incrementally:
        // with photos in timestamp order, each new photo only needs to be compared
        // against the previous one to decide "extend burst vs start new". Files
        // without a readable timestamp sink to the end (sorted by filename among
        // themselves).
        //
        // Parallelize the EXIF reads — each is ~5–10 ms of CGImageSource open
        // + property parse, independent per file, and easily overlaps across
        // CPU cores. 877 photos × 8 ms serial ≈ 7 s of startup; pool width
        // of `ProcessInfo.activeProcessorCount` cuts this to <1 s.
        let filesWithTime: [(url: URL, timestamp: Double?)] = await withTaskGroup(
            of: (Int, URL, Double?).self,
            returning: [(url: URL, timestamp: Double?)].self
        ) { group in
            let detector = burstDetector
            for (idx, url) in scannedFiles.enumerated() {
                group.addTask {
                    (idx, url, detector.readPreciseTimestamp(filePath: url.path))
                }
            }
            var results = Array<(url: URL, timestamp: Double?)>(
                repeating: (URL(fileURLWithPath: ""), nil),
                count: scannedFiles.count
            )
            for await (idx, url, ts) in group {
                results[idx] = (url, ts)
            }
            return results
        }
        let files = filesWithTime.sorted { a, b in
            switch (a.timestamp, b.timestamp) {
            case let (ta?, tb?): return ta < tb
            case (_?, nil): return true
            case (nil, _?): return false
            case (nil, nil): return a.url.lastPathComponent < b.url.lastPathComponent
            }
        }.map(\.url)
        let timestampByPath = Dictionary(uniqueKeysWithValues:
            filesWithTime.compactMap { info in
                info.timestamp.map { (info.url.path, $0) }
            }
        )

        totalCount = files.count
        processedCount = 0

        // Memory budget note: model wrappers run `autoreleasepool { ... }`
        // inside their predict() methods to release MLMultiArray /
        // MLFeatureProvider temporaries at each photo boundary. We also
        // cycle the runtime loop once per iteration via Task.yield() below
        // so ARC gets a scheduled chance to release temporaries between
        // photos.

        let db: ReportDatabase
        do {
            db = try ReportDatabase(folderPath: folder, name: databaseName)
        } catch {
            logger.error("Failed to open database: \(error)")
            return
        }

        // Batch skip-check: one SELECT up-front instead of N round-trips.
        let existingPaths = (try? db.fetchAllFilePaths()) ?? []

        // Running burst state for incremental detection. Photos arrive in
        // timestamp order, so a single comparison against the last photo in
        // `burstPhotos` decides whether the new photo extends the candidate
        // burst or starts a new one.
        var burstPhotos: [Photo] = []
        var burstID: UUID?
        var lastTimestamp: Double?
        var lastPHash: UInt64?
        var sawSkipped = false

        // Finalizer for one photo. Runs serially in timestamp order (one at
        // a time) so the incremental burst state, DB writes, and UI callback
        // stay coherent regardless of which order the concurrent ML tasks
        // actually complete.
        @Sendable
        func finalize(url: URL, workTask: Task<MLWorkResult, Error>) async {
            let startedAt = DispatchTime.now()
            var photo: Photo
            var pHashFromDecoded: UInt64?
            var imageSize: (width: Int, height: Int)?
            do {
                let result = try await workTask.value
                photo = result.photo
                pHashFromDecoded = result.pHash
                imageSize = result.imageSize
            } catch {
                logger.error("Failed to process \(url.lastPathComponent): \(error)")
                photo = Photo(filename: url.lastPathComponent,
                              filePath: url.path, folderPath: folder.path)
                photo.starRating = 0
            }

            do {
                try db.save(&photo)
                try? XMPWriter.write(photo: photo)
            } catch {
                logger.error("Failed to save photo: \(error)")
            }
            processedCount += 1
            let elapsedMs = Double(DispatchTime.now().uptimeNanoseconds - startedAt.uptimeNanoseconds) / 1_000_000
            let species = photo.speciesCommonName ?? "unidentified"
            let conf = photo.speciesConfidence.map { String(format: "%.2f", $0) } ?? "-"
            let sizeStr = imageSize.map { "\($0.width)x\($0.height)" } ?? "-"
            logger.info("processed \(url.lastPathComponent, privacy: .public) size=\(sizeStr, privacy: .public) elapsed=\(String(format: "%.0f", elapsedMs), privacy: .public)ms stars=\(photo.starRating, privacy: .public) species=\(species, privacy: .public) conf=\(conf, privacy: .public)")

            if burstDetectionEnabled {
                let ts = timestampByPath[url.path]
                let pHash: UInt64? = ts != nil ? pHashFromDecoded : nil

                let extendsBurst: Bool = {
                    guard let ts, let lt = lastTimestamp else { return false }
                    let gapMs = (ts - lt) * 1000
                    guard gapMs <= burstDetector.timeThresholdMs else { return false }
                    // Short-circuit: two frames arriving within one-ish
                    // shutter interval (≤100 ms) are treated as same burst
                    // regardless of pHash — at 20 fps a wing flap between
                    // consecutive shots can push hamming above threshold
                    // even though the scene obviously hasn't changed.
                    if gapMs <= 100 { return true }
                    guard let p = pHash, let lp = lastPHash else { return false }
                    return Float(BurstDetector.hammingDistance(lp, p)) <= burstDetector.similarityThreshold
                }()

                if !extendsBurst {
                    burstPhotos.removeAll(keepingCapacity: true)
                    burstID = nil
                }
                burstPhotos.append(photo)

                if burstPhotos.count >= burstDetector.minBurstCount {
                    let groupID = burstID ?? UUID()
                    burstID = groupID
                    let bestID = Self.selectBest(in: burstPhotos)

                    var updated: [Photo] = []
                    for i in burstPhotos.indices {
                        let newBest = (burstPhotos[i].id == bestID)
                        if burstPhotos[i].burstGroupID != groupID || burstPhotos[i].isBurstBest != newBest {
                            burstPhotos[i].burstGroupID = groupID
                            burstPhotos[i].isBurstBest = newBest
                            do {
                                try db.save(&burstPhotos[i])
                                updated.append(burstPhotos[i])
                            } catch {
                                logger.error("Failed to save burst update: \(error)")
                            }
                        }
                    }

                    if let idx = burstPhotos.firstIndex(where: { $0.id == photo.id }) {
                        photo = burstPhotos[idx]
                    }
                    for p in updated where p.id != photo.id {
                        await onPhotoProcessed?(p)
                    }
                }

                if ts != nil { lastTimestamp = ts }
                if pHash != nil { lastPHash = pHash }
            }

            await onPhotoProcessed?(photo)
        }

        // Bounded queue of in-flight ML tasks. Tasks run concurrently (up to
        // `maxConcurrentMLWork`); `finalize` awaits them strictly in the
        // submission order, so the serial post-processing phase sees photos
        // in timestamp order.
        var inflight: [(URL, Task<MLWorkResult, Error>)] = []

        for fileURL in files {
            if Task.isCancelled { break }

            currentFilename = fileURL.lastPathComponent

            if existingPaths.contains(fileURL.path) {
                // Drain in-flight before the skip so the skip's burst reset
                // applies to the true sequential position.
                while let first = inflight.first {
                    inflight.removeFirst()
                    await finalize(url: first.0, workTask: first.1)
                }
                processedCount += 1
                sawSkipped = true
                burstPhotos.removeAll(keepingCapacity: true)
                burstID = nil
                lastTimestamp = nil
                lastPHash = nil
                await onPhotoProcessed?(nil)
                continue
            }

            while inflight.count >= Self.maxConcurrentMLWork {
                let first = inflight.removeFirst()
                await finalize(url: first.0, workTask: first.1)
            }

            let capturedFolder = folder.path
            let task = Task.detached(priority: .userInitiated) { [self] in
                try await self.processMLWork(
                    fileURL: fileURL,
                    folderPath: capturedFolder,
                    ratingConfig: ratingConfig,
                    exposureEnabled: exposureEnabled,
                    exposureThreshold: exposureThreshold,
                    flightDetectionEnabled: flightDetectionEnabled
                )
            }
            inflight.append((fileURL, task))
        }

        // Drain any tasks still in flight when the loop exits.
        while let first = inflight.first {
            inflight.removeFirst()
            await finalize(url: first.0, workTask: first.1)
        }

        // If we skipped existing photos, the running burst window was reset
        // at each skip. Run a full reconciliation so bursts spanning the
        // skip boundary are correct. Fresh-processing runs don't need this.
        if burstDetectionEnabled && sawSkipped {
            await runBurstDetection(db: db, detector: burstDetector)
        }

        // Picked flag calculation (intersection of top aesthetics & sharpness among 5-star)
        await runPickedFlagCalculation(db: db, topPercentage: pickedTopPercentage)
    }

    /// Best photo in a burst: highest combined sharpness + aesthetics score.
    /// Matches BurstDetector.selectBest so the incremental and batch paths agree.
    private static func selectBest(in photos: [Photo]) -> UUID? {
        photos.max(by: { burstScore($0) < burstScore($1) })?.id
    }

    private static func burstScore(_ photo: Photo) -> Float {
        (photo.sharpnessScore ?? 0) * 0.5 + (photo.aestheticsScore ?? 0) * 0.5
    }

    private func runBurstDetection(db: ReportDatabase, detector: BurstDetector) async {
        do {
            let allPhotos = try db.fetchAllPhotos()
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

    /// Sendable result of the async ML work for one photo — lets the outer
    /// loop overlap photo N+1's ML with photo N's serial post-processing.
    struct MLWorkResult: Sendable {
        var photo: Photo
        var pHash: UInt64?
        var imageSize: (width: Int, height: Int)?
    }

    /// Pure async ML work: decode + identify + aesthetics / keypoints /
    /// flight + sharpness / rating. No burst-state, DB, or UI side effects.
    /// Safe to run concurrently from a detached prefetch Task.
    func processMLWork(
        fileURL: URL,
        folderPath: String,
        ratingConfig: RatingEngine.Config,
        exposureEnabled: Bool,
        exposureThreshold: Float,
        flightDetectionEnabled: Bool
    ) async throws -> MLWorkResult {
        var photo = Photo(
            filename: fileURL.lastPathComponent,
            filePath: fileURL.path,
            folderPath: folderPath
        )
        var pHash: UInt64?
        var imageSize: (width: Int, height: Int)?
        try await processOnePhoto(
            &photo,
            fileURL: fileURL,
            ratingConfig: ratingConfig,
            exposureEnabled: exposureEnabled,
            exposureThreshold: exposureThreshold,
            flightDetectionEnabled: flightDetectionEnabled,
            pHashOut: &pHash,
            imageSizeOut: &imageSize
        )
        return MLWorkResult(photo: photo, pHash: pHash, imageSize: imageSize)
    }

    private func processOnePhoto(
        _ photo: inout Photo,
        fileURL: URL,
        ratingConfig: RatingEngine.Config,
        exposureEnabled: Bool,
        exposureThreshold: Float,
        flightDetectionEnabled: Bool,
        pHashOut: inout UInt64?,
        imageSizeOut: inout (width: Int, height: Int)?
    ) async throws {
        // Single-read EXIF: one CGImageSource open powers the original
        // image dimensions (logged for perf correlation), the ISO sharpness
        // factor, and the focus-point weighting below.
        let imageProps = ImageProperties.load(filePath: fileURL.path)
        if let props = imageProps,
           let w = props[kCGImagePropertyPixelWidth as String] as? Int,
           let h = props[kCGImagePropertyPixelHeight as String] as? Int {
            imageSizeOut = (w, h)
        }

        // Decode the 1280 thumbnail up front — identify, OSEA crop,
        // aesthetics / keypoints / flight, and the burst pHash all
        // consume the same pixels; we used to decode twice (once
        // inside identify, once here) which doubled the decode cost.
        let image = try rawConverter.convert(fileURL: fileURL)
        // Perceptual hash for the burst-similarity check — reuse the already
        // decoded image instead of reopening the file for a 64px thumbnail.
        pHashOut = BurstDetector.pHash(from: image)

        // Kick off aesthetics before YOLO/OSEA — it only needs the 1280
        // thumbnail (not the YOLO crop) and runs on `.cpuAndGPU`, so it
        // executes in parallel with identify's ANE work instead of stacking
        // on top of it. Cancellation and drain handled at each early return.
        async let aestheticsResponse = inferenceClient.aesthetics(image: image)

        // YOLO detect + OSEA species identify, reusing `image` as the
        // source so identify skips its own thumbnail decode.
        let identifyResult: IdentifyResponse
        do {
            identifyResult = try await inferenceClient.identify(
                filePath: fileURL.path, topK: 5, preDecodedImage: image
            )
        } catch {
            _ = try? await aestheticsResponse
            throw error
        }

        guard let bird = identifyResult.birds?.first else {
            _ = try? await aestheticsResponse
            photo.starRating = 0
            return
        }
        photo.birdConfidence = bird.confidence
        photo.birdBboxJSON = Self.encodeJSON([
            Float(bird.bbox.minX), Float(bird.bbox.minY),
            Float(bird.bbox.maxX), Float(bird.bbox.maxY),
        ])

        if let top = identifyResult.species.first {
            photo.speciesScientificName = top.scientificName
            photo.speciesCommonName = top.commonName
            photo.speciesCnName = top.cnName
            photo.speciesPinyin = top.pinyin
            photo.speciesConfidence = top.confidence
        }
        if let top5 = identifyResult.top5 {
            photo.speciesTop5JSON = Self.encodeJSON(top5)
        }

        // Smart square crop with 15% padding + letterboxing, matching preen's
        // YOLOBirdDetector.detect_and_crop_bird. The flight / keypoint / OSEA
        // models were all trained on square crops with ~15 % context; feeding
        // a raw rectangular YOLO bbox stretched to their input size causes
        // severe false positives in the flight classifier.
        guard let birdCrop = image.smartSquareBirdCrop(bbox: bird.bbox) else {
            _ = try? await aestheticsResponse
            photo.starRating = 0
            return
        }

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

        // `imageProps` (loaded at the top) also feeds the ISO sharpness
        // factor and the focus-point weighting below — one CGImageSource
        // open per photo, reused by every downstream consumer.
        let exif = imageProps.map { EXIFReader.parse(properties: $0, imagePath: fileURL.path) }
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

        let focusWeights: FocusPointDetector.FocusWeights = {
            if let props = imageProps {
                return FocusPointDetector.computeWeights(
                    properties: props,
                    birdBbox: bird.bbox,
                    eyeCenter: bestEye,
                    headRadiusFraction: HeadSharpness.noBeakRadiusRatio,
                    segMask: segMask,
                    maskWidth: maskWidth,
                    maskHeight: maskHeight
                )
            }
            // File was unreadable above; preserve original behavior and
            // fall back to the file-path API which also returns `.unknown`.
            return FocusPointDetector.computeWeights(
                filePath: fileURL.path,
                birdBbox: bird.bbox,
                eyeCenter: bestEye,
                headRadiusFraction: HeadSharpness.noBeakRadiusRatio,
                segMask: segMask,
                maskWidth: maskWidth,
                maskHeight: maskHeight
            )
        }()

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
