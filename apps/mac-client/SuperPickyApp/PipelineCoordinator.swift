import Foundation
import CoreGraphics
import ImageIO
import SuperPickyInference
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
    private let reverseGeocoder = ReverseGeocoder()
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
    ///
    /// 6 is the sweet spot on an M3 Max / 64 GB machine: swept 3→4→5→6→8
    /// against the full `~/photo` bench and measured 46 / 39 / 39 / 36 / 37 s
    /// respectively. The ANE has enough internal parallelism that stepping
    /// past 3 helps once the SpeciesFilter GPS serialization is removed
    /// (commit 9e38fe2); 8 regresses slightly on memory pressure.
    private static let maxConcurrentMLWork = 6

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
        let pipelineStart = DispatchTime.now()

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

        // Pre-pass: read timestamp + GPS per file in parallel. Sort by
        // timestamp so burst detection can run incrementally (each photo
        // compared only against the previous); files without timestamps
        // sort to the end by filename.
        struct PrePassInfo: Sendable {
            let url: URL
            let timestamp: Double?
            let gps: (lat: Double, lon: Double)?
        }
        // Cap concurrency: Apple's RawCamera.bundle LRU cache is not
        // thread-safe under unbounded RAW `CGImageSourceCopyPropertiesAtIndex`
        // fan-out (SIGSEGV in `_value_entry_release`). Beyond ~6 threads the
        // XMP parser mutex serializes anyway, so the cap costs nothing.
        let prePassWidth = Self.maxConcurrentMLWork
        let filesWithTime: [PrePassInfo] = await withTaskGroup(
            of: (Int, PrePassInfo).self,
            returning: [PrePassInfo].self
        ) { group in
            var results = [PrePassInfo](
                repeating: PrePassInfo(url: URL(fileURLWithPath: ""), timestamp: nil, gps: nil),
                count: scannedFiles.count
            )
            var nextIdx = 0
            let initial = min(prePassWidth, scannedFiles.count)
            while nextIdx < initial {
                let idx = nextIdx
                let url = scannedFiles[idx]
                group.addTask {
                    let result = BurstDetector.readPreciseTimestampAndGPS(filePath: url.path)
                    return (idx, PrePassInfo(url: url, timestamp: result.timestamp, gps: result.gps))
                }
                nextIdx += 1
            }
            for await (idx, info) in group {
                results[idx] = info
                if nextIdx < scannedFiles.count {
                    let nIdx = nextIdx
                    let url = scannedFiles[nIdx]
                    group.addTask {
                        let result = BurstDetector.readPreciseTimestampAndGPS(filePath: url.path)
                        return (nIdx, PrePassInfo(url: url, timestamp: result.timestamp, gps: result.gps))
                    }
                    nextIdx += 1
                }
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

        // One pass: timestampByPath + gpsByPath + unique-cells dedup for
        // the SpeciesFilter pre-warm. Without pre-warming, the first six
        // concurrent identifies all cache-miss the Avonet SQLite lookup
        // simultaneously and serialize on the FULLMUTEX lock.
        var timestampByPath: [String: Double] = [:]
        var gpsByPath: [String: (lat: Double, lon: Double)] = [:]
        var seenCells = Set<UInt64>()
        var uniqueCells: [(lat: Double, lon: Double)] = []
        timestampByPath.reserveCapacity(filesWithTime.count)
        gpsByPath.reserveCapacity(filesWithTime.count)
        for info in filesWithTime {
            if let ts = info.timestamp { timestampByPath[info.url.path] = ts }
            guard let gps = info.gps else { continue }
            gpsByPath[info.url.path] = gps
            if seenCells.insert(GPSCell.key(lat: gps.lat, lon: gps.lon)).inserted {
                uniqueCells.append(gps)
            }
        }
        await inferenceClient.prewarmGPSCells(uniqueCells)

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

        // Parallel write-behind across N serial lanes. Writes for the
        // same photo must stay in one lane (initial save + burst-flag
        // update race otherwise), so the lane is derived from the
        // photo path. Called only from the serial finalize loop.
        let writeBehindLanes = 4
        var writeBehindChains: [Task<Void, Never>] =
            (0..<writeBehindLanes).map { _ in Task {} }
        @Sendable
        func writeBehind(key: String, _ work: @escaping @Sendable () async -> Void) {
            let lane = Int(UInt(bitPattern: key.hashValue) % UInt(writeBehindLanes))
            let prev = writeBehindChains[lane]
            writeBehindChains[lane] = Task.detached(priority: .utility) {
                _ = await prev.value
                await work()
            }
        }
        @Sendable
        func allWriteBehindLanes() async {
            await withTaskGroup(of: Void.self) { group in
                for chain in writeBehindChains {
                    group.addTask { _ = await chain.value }
                }
            }
        }

        // Finalizer for one photo. Runs serially in timestamp order (one at
        // a time) so the incremental burst state, DB writes, and UI callback
        // stay coherent regardless of which order the concurrent ML tasks
        // actually complete.
        @Sendable
        func finalize(url: URL, workTask: Task<MLWorkResult, Error>) async {
            if Task.isCancelled {
                workTask.cancel()
                return
            }
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

            let snapshot = photo
            let gpsCoord = gpsByPath[url.path]
            writeBehind(key: url.path) { [logger, reverseGeocoder = self.reverseGeocoder] in
                var p = snapshot
                if let gps = gpsCoord,
                   let loc = await reverseGeocoder.resolve(lat: gps.lat, lon: gps.lon) {
                    p.applyLocation(loc)
                }
                do { try db.save(&p) } catch {
                    logger.error("Failed to save photo: \(error)")
                }
                try? XMPWriter.write(photo: p)
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
                    let donor = Self.speciesDonor(in: burstPhotos)

                    var updated: [Photo] = []
                    for i in burstPhotos.indices {
                        let newBest = (burstPhotos[i].id == bestID)
                        let shouldInherit = donor != nil
                            && !burstPhotos[i].hasSpecies
                            && burstPhotos[i].id != donor!.id
                        let flagsChanged = burstPhotos[i].burstGroupID != groupID
                            || burstPhotos[i].isBurstBest != newBest
                        if flagsChanged || shouldInherit {
                            burstPhotos[i].burstGroupID = groupID
                            burstPhotos[i].isBurstBest = newBest
                            if shouldInherit, let donor {
                                burstPhotos[i].inheritSpecies(from: donor)
                            }
                            let toSave = burstPhotos[i]
                            let burstGPS = gpsByPath[toSave.filePath]
                            let rewriteXMP = shouldInherit
                            writeBehind(key: toSave.filePath) { [logger, reverseGeocoder = self.reverseGeocoder] in
                                var p = toSave
                                // GRDB save is a full REPLACE; re-apply location so
                                // the burst update doesn't clobber it.
                                if let gps = burstGPS,
                                   let loc = await reverseGeocoder.resolve(lat: gps.lat, lon: gps.lon) {
                                    p.applyLocation(loc)
                                }
                                do { try db.save(&p) } catch {
                                    logger.error("Failed to save burst update: \(error)")
                                }
                                // Only rewrite the sidecar when species
                                // actually changed — burst-flag-only
                                // updates don't surface in XMP.
                                if rewriteXMP { try? XMPWriter.write(photo: p) }
                            }
                            updated.append(burstPhotos[i])
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
                // Resumption: already-processed photos are in DB from an
                // earlier run. Skip ML, but drain in-flight first and
                // reset the incremental burst window so a new photo
                // after the skip doesn't accidentally extend a burst
                // that pre-dates the skip. Cross-skip bursts aren't
                // detected — a known gap the streaming pipeline will
                // close.
                while let first = inflight.first {
                    inflight.removeFirst()
                    await finalize(url: first.0, workTask: first.1)
                }
                processedCount += 1
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
            let preGPS = gpsByPath[fileURL.path]
            let task = Task.detached(priority: .userInitiated) { [self] in
                try await self.processMLWork(
                    fileURL: fileURL,
                    folderPath: capturedFolder,
                    ratingConfig: ratingConfig,
                    exposureEnabled: exposureEnabled,
                    exposureThreshold: exposureThreshold,
                    flightDetectionEnabled: flightDetectionEnabled,
                    preGPS: preGPS
                )
            }
            inflight.append((fileURL, task))
        }

        // Cancellation: cancel inflight, skip final drain + picked-flag.
        // Write-behind chain keeps running in the background so already-
        // finalized photos still save.
        if Task.isCancelled {
            for (_, task) in inflight { task.cancel() }
            inflight.removeAll()
            let count = self.processedCount
            logger.notice("pipeline.cancelled after=\(String(format: "%.0f", Double(DispatchTime.now().uptimeNanoseconds - pipelineStart.uptimeNanoseconds) / 1_000_000), privacy: .public)ms processed=\(count, privacy: .public)")
            return
        }

        // Normal completion: drain everything in order.
        while let first = inflight.first {
            inflight.removeFirst()
            await finalize(url: first.0, workTask: first.1)
        }
        let mlEnd = DispatchTime.now()

        await allWriteBehindLanes()
        let wbEnd = DispatchTime.now()

        await runPickedFlagCalculation(db: db, topPercentage: pickedTopPercentage)
        let allEnd = DispatchTime.now()
        let mlMs = Double(mlEnd.uptimeNanoseconds - pipelineStart.uptimeNanoseconds) / 1_000_000
        let wbTailMs = Double(wbEnd.uptimeNanoseconds - mlEnd.uptimeNanoseconds) / 1_000_000
        let finalMs = Double(allEnd.uptimeNanoseconds - wbEnd.uptimeNanoseconds) / 1_000_000
        logger.notice("pipeline.finished ml=\(String(format: "%.0f", mlMs), privacy: .public)ms wbTail=\(String(format: "%.0f", wbTailMs), privacy: .public)ms final=\(String(format: "%.0f", finalMs), privacy: .public)ms total=\(String(format: "%.0f", mlMs + wbTailMs + finalMs), privacy: .public)ms")
    }

    /// Best photo in a burst: highest combined sharpness + aesthetics score.
    /// Matches BurstDetector.selectBest so the incremental and batch paths agree.
    private static func selectBest(in photos: [Photo]) -> UUID? {
        photos.max(by: { burstScore($0) < burstScore($1) })?.id
    }

    private static func burstScore(_ photo: Photo) -> Float {
        (photo.sharpnessScore ?? 0) * 0.5 + (photo.aestheticsScore ?? 0) * 0.5
    }

    /// The member whose species label we'll copy into any unidentified
    /// sibling — the highest-confidence ID in the burst.
    private static func speciesDonor(in photos: [Photo]) -> Photo? {
        photos
            .filter { $0.hasSpecies }
            .max { ($0.speciesConfidence ?? 0) < ($1.speciesConfidence ?? 0) }
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
        flightDetectionEnabled: Bool,
        preGPS: (lat: Double, lon: Double)? = nil
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
            preGPS: preGPS,
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
        preGPS: (lat: Double, lon: Double)?,
        pHashOut: inout UInt64?,
        imageSizeOut: inout (width: Int, height: Int)?
    ) async throws {
        let photoStart = DispatchTime.now()
        // One CGImageSource open per photo — extract both the 1280 thumbnail
        // and the EXIF/TIFF property dictionary together. Every consumer
        // downstream (ISO sharpness factor, focus-point weighting, image
        // dimensions logged below) wants a slice of the same property dict;
        // re-opening the source for properties after the thumbnail decode
        // used to cost ~4 ms / photo.
        let decodeStart = DispatchTime.now()
        let decoded = try rawConverter.decode(fileURL: fileURL)
        let image = decoded.image
        let imageProps = decoded.properties
        let decodeMs = Self.elapsedMs(since: decodeStart)
        if let props = imageProps,
           let w = props[kCGImagePropertyPixelWidth as String] as? Int,
           let h = props[kCGImagePropertyPixelHeight as String] as? Int {
            imageSizeOut = (w, h)
        }
        // Perceptual hash for the burst-similarity check — reuse the already
        // decoded image instead of reopening the file for a 64px thumbnail.
        let pHashStart = DispatchTime.now()
        pHashOut = BurstDetector.pHash(from: image)
        let pHashMs = Self.elapsedMs(since: pHashStart)

        // YOLO detect + OSEA species identify, reusing `image` and the
        // pre-pass GPS so identify skips its thumbnail decode AND its
        // second CGImageSource open for the GPS IFD.
        let identifyResult = try await inferenceClient.identify(
            filePath: fileURL.path, topK: 5,
            preDecodedImage: image, preGPS: preGPS
        )

        guard let bird = identifyResult.birds?.first else {
            photo.starRating = 0
            return
        }
        photo.birdConfidence = bird.confidence
        photo.birdBboxJSON = Self.encodeJSON([
            Float(bird.bbox.minX), Float(bird.bbox.minY),
            Float(bird.bbox.maxX), Float(bird.bbox.maxY),
        ])

        if let top = identifyResult.species.first {
            // Writing `assignedSpecies` mirrors the primary SpeciesMatch
            // into the scalar species* columns, so we avoid setting them
            // twice.
            photo.assignedSpecies = [top]
        } else {
            photo.assignedSpecies = []
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
            photo.starRating = 0
            return
        }

        let postMlStart = DispatchTime.now()
        async let aestheticsResponse = inferenceClient.aesthetics(image: image)
        async let keypointResult = inferenceClient.keypoints(image: birdCrop)
        async let flightResult = flightDetectionEnabled
            ? inferenceClient.flight(image: birdCrop)
            : FlightResult(isFlying: false, confidence: 0)

        let (aesthetics, keypoints, flight) = try await (aestheticsResponse, keypointResult, flightResult)
        let postMlMs = Self.elapsedMs(since: postMlStart)

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

        let photoMs = Self.elapsedMs(since: photoStart)
        logger.debug("photo.ml decode=\(decodeMs, privacy: .public)ms pHash=\(pHashMs, privacy: .public)ms postMl=\(postMlMs, privacy: .public)ms total=\(photoMs, privacy: .public)ms")
    }

    private static func elapsedMs(since start: DispatchTime) -> String {
        let ns = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return String(format: "%.1f", Double(ns) / 1_000_000)
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
