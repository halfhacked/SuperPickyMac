import Foundation
import CoreGraphics
import ImageIO
import SuperPickyInference
import UniformTypeIdentifiers
import os

private final class RawReadLimiter: @unchecked Sendable {
    private let semaphore: DispatchSemaphore

    init(limit: Int) {
        semaphore = DispatchSemaphore(value: limit)
    }

    func withPermit<T>(_ operation: () throws -> T) rethrows -> T {
        semaphore.wait()
        defer { semaphore.signal() }
        return try operation()
    }

    func withPermitUnlessCancelled<T>(_ operation: () -> T) -> T? {
        while semaphore.wait(timeout: .now() + .milliseconds(20)) == .timedOut {
            if Task.isCancelled { return nil }
        }
        defer { semaphore.signal() }
        guard !Task.isCancelled else { return nil }
        return operation()
    }
}

@Observable
final class PipelineCoordinator: @unchecked Sendable {
    private let inferenceClient: InferenceClient
    private let ratingEngine = RatingEngine()
    private let exposureDetector = ExposureDetector()
    private let rawConverter = RAWConverter()
    private let scanner = DirectoryScanner()
    private let reverseGeocoder = ReverseGeocoder()
    private let logger = Logger(subsystem: "com.halfhacked.superpicky", category: "Pipeline")
    private let rawReadLimiter = RawReadLimiter(limit: maxConcurrentMLWork)
    private let initialMetadataBatchSize: Int
    private let metadataBatchSize: Int

    var totalCount = 0
    var processedCount = 0
    var currentFilename = ""
    var isProcessing = false

    /// Max photos whose ML work (decode + YOLO + OSEA + aesthetics/keypoints/
    /// flight) may be in flight simultaneously. Compute-unit split pins
    /// Aesthetics to GPU and OSEA/Keypoint/Flight to ANE so several photos'
    /// work can truly overlap across engines. Post-processing (DB, burst
    /// state and UI callbacks) run in ingestion order; burst reconciliation
    /// is applied once in exact capture-time order after ingestion.
    ///
    /// 6 is the sweet spot on an M3 Max / 64 GB machine: swept 3→4→5→6→8
    /// against the full `~/photo` bench and measured 46 / 39 / 39 / 36 / 37 s
    /// respectively. The ANE has enough internal parallelism that stepping
    /// past 3 helps once the SpeciesFilter GPS serialization is removed
    /// (commit 9e38fe2); 8 regresses slightly on memory pressure.
    private static let maxConcurrentMLWork = 6

    init(
        inferenceClient: InferenceClient,
        initialMetadataBatchSize: Int = 64,
        metadataBatchSize: Int = 512
    ) {
        self.inferenceClient = inferenceClient
        self.initialMetadataBatchSize = max(1, initialMetadataBatchSize)
        self.metadataBatchSize = max(1, metadataBatchSize)
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
        databaseName: String = ".report.db",
        onPhotoProcessed: (@Sendable (Photo?) async -> Void)? = nil
    ) async {
        isProcessing = true
        defer { isProcessing = false }
        let pipelineStart = DispatchTime.now()

        // Build a local BurstDetector with the user-configured thresholds.
        // Time threshold derives from the configured burst FPS plus a 1.5×
        // tolerance — at 20 fps this gives 75 ms (tight), at 10 fps this
        // gives 150 ms, and a floor of 50 ms prevents divide-by-zero.
        let burstTimeThresholdMs = max(50.0, 1000.0 / Double(max(1, burstFps)) * 1.5)
        let burstDetector = BurstDetector(
            timeThresholdMs: burstTimeThresholdMs,
            minBurstCount: burstMinCount,
            similarityThreshold: Float(burstHashTolerance)
        )

        let scanStart = DispatchTime.now()
        let scannedFiles: [URL]
        do {
            scannedFiles = try scanner.scan(folder: folder)
        } catch {
            logger.error("Failed to scan folder: \(error)")
            return
        }
        let scanEnd = DispatchTime.now()

        let db: ReportDatabase
        do {
            db = try ReportDatabase(folderPath: folder, name: databaseName)
        } catch {
            logger.error("Failed to open database: \(error)")
            return
        }

        // Resume work only needs metadata and ML for paths not already in
        // the report DB. The UI is seeded from the DB before this method is
        // called, so replaying one callback per existing photo adds no value.
        let existingDates = (try? db.fetchAllFileDates()) ?? [:]
        let existingPaths = Set(existingDates.keys)
        let pendingFiles = scannedFiles.filter { !existingPaths.contains($0.path) }
        totalCount = scannedFiles.count
        processedCount = scannedFiles.count - pendingFiles.count
        if processedCount > 0 {
            await onPhotoProcessed?(nil)
        }
        logger.notice(
            "pipeline.inventory scan=\(String(format: "%.0f", Double(scanEnd.uptimeNanoseconds - scanStart.uptimeNanoseconds) / 1_000_000), privacy: .public)ms total=\(self.totalCount, privacy: .public) existing=\(self.processedCount, privacy: .public) pending=\(pendingFiles.count, privacy: .public)"
        )

        let scannedPaths = Set(scannedFiles.map(\.path))
        let pendingPaths = Set(pendingFiles.map(\.path))

        // Metadata is prepared in bounded batches. The first small batch
        // reaches ML quickly; while ML consumes it, the next larger batch
        // reads timestamp/GPS and prewarms Avonet in parallel. A shared gate
        // keeps total RawCamera reads at the proven-safe concurrency of six.
        var timestampByPath: [String: Double] = [:]
        var gpsByPath: [String: (lat: Double, lon: Double)] = [:]
        var pHashByPath: [String: UInt64] = [:]
        timestampByPath.reserveCapacity(pendingFiles.count)
        gpsByPath.reserveCapacity(pendingFiles.count)
        pHashByPath.reserveCapacity(pendingFiles.count)

        // Memory budget note: model wrappers run `autoreleasepool { ... }`
        // inside their predict() methods to release MLMultiArray /
        // MLFeatureProvider temporaries at each photo boundary. We also
        // cycle the runtime loop once per iteration via Task.yield() below
        // so ARC gets a scheduled chance to release temporaries between
        // photos.

        // Parallel write-behind across N serial lanes. Writes for the
        // same photo must stay in one lane (initial save + burst-flag
        // update race otherwise), so the lane is derived from the
        // photo path. Called only from the serial finalize loop.
        let writeBehindLanes = 4
        var writeBehindChains: [Task<Void, Never>] =
            (0..<writeBehindLanes).map { _ in Task {} }
        func writeBehind(key: String, _ work: @escaping @Sendable () async -> Void) {
            let lane = Int(UInt(bitPattern: key.hashValue) % UInt(writeBehindLanes))
            let prev = writeBehindChains[lane]
            writeBehindChains[lane] = Task.detached(priority: .utility) {
                _ = await prev.value
                await work()
            }
        }
        func allWriteBehindLanes() async {
            await withTaskGroup(of: Void.self) { group in
                for chain in writeBehindChains {
                    group.addTask { _ = await chain.value }
                }
            }
        }

        // Finalizer for one photo. Burst assignment is intentionally deferred
        // until every processed photo can be ordered by capture timestamp.
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
                if let pHashFromDecoded {
                    pHashByPath[url.path] = pHashFromDecoded
                }
            } catch {
                logger.error("Failed to process \(url.lastPathComponent): \(error)")
                photo = Photo(filename: url.lastPathComponent,
                              filePath: url.path, folderPath: folder.path)
                if let timestamp = timestampByPath[url.path] {
                    photo.dateCreated = Date(timeIntervalSince1970: timestamp)
                }
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
                _ = try? XMPWriter.write(photo: p)
            }
            processedCount += 1
            let elapsedMs = Self.elapsedMilliseconds(since: startedAt)
            let species = photo.speciesCommonName ?? "unidentified"
            let conf = photo.speciesConfidence.map { String(format: "%.2f", $0) } ?? "-"
            let sizeStr = imageSize.map { "\($0.width)x\($0.height)" } ?? "-"
            logger.info("processed \(url.lastPathComponent, privacy: .public) size=\(sizeStr, privacy: .public) elapsed=\(String(format: "%.0f", elapsedMs), privacy: .public)ms stars=\(photo.starRating, privacy: .public) species=\(species, privacy: .public) conf=\(conf, privacy: .public)")

            await onPhotoProcessed?(photo)
        }

        // Bounded queue of in-flight ML tasks. Tasks run concurrently (up to
        // `maxConcurrentMLWork`); `finalize` awaits them strictly in the
        // submission order. Exact timestamp ordering is applied once, during
        // the final burst reconciliation.
        var inflight: [(URL, Task<MLWorkResult, Error>)] = []

        var nextBatchStart = 0
        var metadataTask: Task<MetadataBatch?, Never>?

        func prepareNextMetadataBatch() -> Task<MetadataBatch?, Never>? {
            guard nextBatchStart < pendingFiles.count else { return nil }
            let batchSize = nextBatchStart == 0
                ? initialMetadataBatchSize
                : metadataBatchSize
            let end = min(nextBatchStart + batchSize, pendingFiles.count)
            let urls = Array(pendingFiles[nextBatchStart..<end])
            nextBatchStart = end
            return Task.detached(priority: .userInitiated) { [self] in
                let started = DispatchTime.now()
                let infos = await self.loadMetadata(for: urls)
                guard !Task.isCancelled else { return nil }
                let metadataMs = Self.elapsedMilliseconds(since: started)
                var seenCells = Set<UInt64>()
                var cells: [(lat: Double, lon: Double)] = []
                for info in infos {
                    guard let gps = info.gps else { continue }
                    if seenCells.insert(GPSCell.key(lat: gps.lat, lon: gps.lon)).inserted {
                        cells.append(gps)
                    }
                }
                let prewarmStart = DispatchTime.now()
                await self.inferenceClient.prewarmGPSCells(cells)
                guard !Task.isCancelled else { return nil }
                return MetadataBatch(
                    infos: infos,
                    metadataMs: metadataMs,
                    prewarmMs: Self.elapsedMilliseconds(since: prewarmStart),
                    gpsCellCount: cells.count
                )
            }
        }

        metadataTask = prepareNextMetadataBatch()
        var metadataBatchIndex = 0
        while let currentMetadataTask = metadataTask {
            if Task.isCancelled {
                currentMetadataTask.cancel()
                _ = await currentMetadataTask.value
                metadataTask = nil
                break
            }

            let batch = await withTaskCancellationHandler {
                await currentMetadataTask.value
            } onCancel: {
                currentMetadataTask.cancel()
            }
            guard let batch else {
                metadataTask = nil
                break
            }
            metadataTask = prepareNextMetadataBatch()
            metadataBatchIndex += 1
            if metadataBatchIndex == 1 {
                logger.notice(
                    "pipeline.firstBatch metadata=\(String(format: "%.0f", batch.metadataMs), privacy: .public)ms files=\(batch.infos.count, privacy: .public) gpsCells=\(batch.gpsCellCount, privacy: .public) prewarm=\(String(format: "%.1f", batch.prewarmMs), privacy: .public)ms"
                )
            }

            for info in batch.infos {
                if let timestamp = info.timestamp {
                    timestampByPath[info.url.path] = timestamp
                }
                if let gps = info.gps {
                    gpsByPath[info.url.path] = gps
                }

                if Task.isCancelled { break }
                let fileURL = info.url
                currentFilename = fileURL.lastPathComponent

                while inflight.count >= Self.maxConcurrentMLWork {
                    let first = inflight.removeFirst()
                    await finalize(url: first.0, workTask: first.1)
                }

                let capturedFolder = folder.path
                let preGPS = info.gps
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
        }

        // Cancellation: cancel inflight, skip final drain.
        if Task.isCancelled {
            metadataTask?.cancel()
            _ = await metadataTask?.value
            for (_, task) in inflight { task.cancel() }
            inflight.removeAll()
            await allWriteBehindLanes()
            if burstDetectionEnabled {
                await reconcileBursts(
                    db: db,
                    scannedPaths: scannedPaths,
                    pendingPaths: pendingPaths,
                    existingDates: existingDates,
                    timestampByPath: timestampByPath,
                    pHashByPath: pHashByPath,
                    detector: burstDetector,
                    onPhotoProcessed: onPhotoProcessed
                )
            }
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
        if burstDetectionEnabled {
            await reconcileBursts(
                db: db,
                scannedPaths: scannedPaths,
                pendingPaths: pendingPaths,
                existingDates: existingDates,
                timestampByPath: timestampByPath,
                pHashByPath: pHashByPath,
                detector: burstDetector,
                onPhotoProcessed: onPhotoProcessed
            )
        }
        let wbEnd = DispatchTime.now()

        let mlMs = Double(mlEnd.uptimeNanoseconds - pipelineStart.uptimeNanoseconds) / 1_000_000
        let wbTailMs = Double(wbEnd.uptimeNanoseconds - mlEnd.uptimeNanoseconds) / 1_000_000
        logger.notice("pipeline.finished ml=\(String(format: "%.0f", mlMs), privacy: .public)ms wbTail=\(String(format: "%.0f", wbTailMs), privacy: .public)ms total=\(String(format: "%.0f", mlMs + wbTailMs), privacy: .public)ms")
    }

    private func loadMetadata(for urls: [URL]) async -> [PrePassInfo] {
        await withTaskGroup(
            of: (Int, PrePassInfo?).self,
            returning: [PrePassInfo].self
        ) { group in
            var results = [PrePassInfo?](
                repeating: nil,
                count: urls.count
            )

            func addTask(for index: Int) {
                let url = urls[index]
                group.addTask { [rawReadLimiter] in
                    guard let result = rawReadLimiter.withPermitUnlessCancelled({
                        BurstDetector.readPreciseTimestampAndGPS(filePath: url.path)
                    }) else { return (index, nil) }
                    return (
                        index,
                        PrePassInfo(
                            url: url,
                            timestamp: result.timestamp,
                            gps: result.gps
                        )
                    )
                }
            }

            var nextIndex = 0
            let initial = min(Self.maxConcurrentMLWork, urls.count)
            while nextIndex < initial {
                addTask(for: nextIndex)
                nextIndex += 1
            }
            for await (index, info) in group {
                results[index] = info
                if !Task.isCancelled, nextIndex < urls.count {
                    addTask(for: nextIndex)
                    nextIndex += 1
                }
            }
            return results.compactMap { $0 }
        }
    }

    private func reconcileBursts(
        db: ReportDatabase,
        scannedPaths: Set<String>,
        pendingPaths: Set<String>,
        existingDates: [String: Date],
        timestampByPath: [String: Double],
        pHashByPath: [String: UInt64],
        detector: BurstDetector,
        onPhotoProcessed: (@Sendable (Photo?) async -> Void)?
    ) async {
        let allPhotos: [Photo]
        do {
            allPhotos = try db.fetchAllPhotos()
        } catch {
            logger.error("Failed to load photos for burst reconciliation: \(error)")
            return
        }

        let photosByPath = Dictionary(
            uniqueKeysWithValues: allPhotos
                .filter { scannedPaths.contains($0.filePath) }
                .map { ($0.filePath, $0) }
        )
        var sequence: [BurstSequenceEntry] = []
        sequence.reserveCapacity(photosByPath.count)
        for (path, date) in existingDates where scannedPaths.contains(path) {
            sequence.append(BurstSequenceEntry(
                path: path,
                timestamp: date.timeIntervalSince1970,
                photo: nil
            ))
        }
        for path in pendingPaths {
            guard let photo = photosByPath[path] else { continue }
            sequence.append(BurstSequenceEntry(
                path: path,
                timestamp: timestampByPath[path],
                photo: photo
            ))
        }
        sequence.sort {
            switch ($0.timestamp, $1.timestamp) {
            case let (lhs?, rhs?) where lhs != rhs: return lhs < rhs
            case (_?, nil): return true
            case (nil, _?): return false
            default:
                let lhsName = URL(fileURLWithPath: $0.path).lastPathComponent
                let rhsName = URL(fileURLWithPath: $1.path).lastPathComponent
                return lhsName < rhsName
            }
        }

        var candidate: [Photo] = []
        var lastTimestamp: Double?
        var lastPHash: UInt64?
        var updates: [Photo] = []
        var xmpUpdates: [Photo] = []

        func flushCandidate() {
            defer {
                candidate.removeAll(keepingCapacity: true)
                lastTimestamp = nil
                lastPHash = nil
            }
            guard candidate.count >= detector.minBurstCount else { return }

            let groupID = UUID()
            let bestID = Self.selectBest(in: candidate)
            let donor = Self.speciesDonor(in: candidate)
            for index in candidate.indices {
                candidate[index].burstGroupID = groupID
                candidate[index].isBurstBest = candidate[index].id == bestID
                if let donor,
                   !candidate[index].hasSpecies,
                   candidate[index].id != donor.id {
                    candidate[index].inheritSpecies(from: donor)
                    xmpUpdates.append(candidate[index])
                }
                updates.append(candidate[index])
            }
        }

        for entry in sequence {
            guard let photo = entry.photo else {
                flushCandidate()
                continue
            }
            guard let timestamp = entry.timestamp else {
                flushCandidate()
                candidate.append(photo)
                flushCandidate()
                continue
            }

            let pHash = pHashByPath[entry.path]
            let extendsBurst: Bool
            if let previousTimestamp = lastTimestamp {
                let gapMs = (timestamp - previousTimestamp) * 1000
                if gapMs > detector.timeThresholdMs {
                    extendsBurst = false
                } else if gapMs <= 100 {
                    extendsBurst = true
                } else if let pHash, let lastPHash {
                    extendsBurst = Float(
                        BurstDetector.hammingDistance(lastPHash, pHash)
                    ) <= detector.similarityThreshold
                } else {
                    extendsBurst = false
                }
            } else {
                extendsBurst = false
            }

            if !extendsBurst {
                flushCandidate()
            }
            candidate.append(photo)
            lastTimestamp = timestamp
            lastPHash = pHash
        }
        flushCandidate()

        guard !updates.isEmpty else { return }
        do {
            try db.saveAll(&updates)
        } catch {
            logger.error("Failed to save burst reconciliation: \(error)")
            return
        }
        for photo in xmpUpdates {
            _ = try? XMPWriter.write(photo: photo)
        }
        for photo in updates {
            await onPhotoProcessed?(photo)
        }
        logger.notice("pipeline.bursts reconciled=\(updates.count, privacy: .public)")
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

    /// Sendable result of the async ML work for one photo — lets the outer
    /// loop overlap photo N+1's ML with photo N's serial post-processing.
    struct MLWorkResult: Sendable {
        var photo: Photo
        var pHash: UInt64?
        var imageSize: (width: Int, height: Int)?
    }

    private struct PrePassInfo: Sendable {
        let url: URL
        let timestamp: Double?
        let gps: (lat: Double, lon: Double)?
    }

    private struct MetadataBatch: Sendable {
        let infos: [PrePassInfo]
        let metadataMs: Double
        let prewarmMs: Double
        let gpsCellCount: Int
    }

    private struct BurstSequenceEntry {
        let path: String
        let timestamp: Double?
        let photo: Photo?
    }

    private struct SharpnessPreparation: Sendable {
        let birdCrop: CGImage
        let segmentationMask: [UInt8]?
        let bboxSize: (width: Int, height: Int)
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
        let decoded = try rawReadLimiter.withPermit {
            try rawConverter.decode(fileURL: fileURL)
        }
        let image = decoded.image
        let imageProps = decoded.properties
        let decodeMs = Self.elapsedMs(since: decodeStart)
        if let props = imageProps,
           let w = props[kCGImagePropertyPixelWidth as String] as? Int,
           let h = props[kCGImagePropertyPixelHeight as String] as? Int {
            imageSizeOut = (w, h)
        }
        // EXIF DateTimeOriginal + SubSecTimeOriginal — overrides the ingestion-
        // time `Date()` set by Photo.init so the strip and the captureDate
        // sort actually reflect when the shutter fired.
        if let props = imageProps,
           let ts = BurstDetector.parseTimestamp(from: props) {
            photo.dateCreated = Date(timeIntervalSince1970: ts)
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

        // Keep every identified species from every YOLO detection (preen
        // parity — `preen/detector.py` appends each detection's top-1 and
        // the caller writes them all as keywords). Dedupe by `speciesID`
        // keeping the highest confidence; sort descending so the scalar
        // species* columns mirror the *most confident* detection, not
        // merely the first one YOLO returned.
        var uniqueByID: [String: SpeciesMatch] = [:]
        for match in identifyResult.species {
            if let existing = uniqueByID[match.speciesID],
               existing.confidence >= match.confidence { continue }
            uniqueByID[match.speciesID] = match
        }
        photo.assignedSpecies = uniqueByID.values.sorted { $0.confidence > $1.confidence }
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

        // High-resolution decode and mask alignment are independent of the
        // three post-detection models. Start them now so CPU/JPEG work overlaps
        // GPU inference instead of extending the per-photo critical path.
        async let sharpnessPreparation = Self.prepareSharpness(
            rawReadLimiter: rawReadLimiter,
            rawConverter: rawConverter,
            fileURL: fileURL,
            inferenceImage: image,
            bird: bird,
            fallbackCrop: birdCrop
        )

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

        // Head-region sharpness (circular mask around eye, matches superpicky).
        // Decode at `RAWConverter.maxSharpnessSize` for discrimination;
        // fall back to the inference image when the hi-res decode isn't
        // available (older RAW with no embedded preview).
        let sharpness = await sharpnessPreparation
        let headSharpness = HeadSharpness.score(
            birdCrop: sharpness.birdCrop,
            leftEyeX: keypoints.leftEye.x, leftEyeY: keypoints.leftEye.y,
            leftEyeVis: keypoints.leftEye.visibility,
            rightEyeX: keypoints.rightEye.x, rightEyeY: keypoints.rightEye.y,
            rightEyeVis: keypoints.rightEye.visibility,
            beakX: keypoints.beak.x, beakY: keypoints.beak.y,
            beakVis: keypoints.beak.visibility,
            segMask: sharpness.segmentationMask,
            birdBboxSize: sharpness.bboxSize
        ) ?? TenengradSharpness.score(image: sharpness.birdCrop) // fallback to full-crop

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

        // Head-circle radius for the focus-point .headFocus tier. Mirrors
        // the radius HeadSharpness uses: eye-beak distance × 1.2 when the
        // beak is visible, otherwise the bbox max-side × 0.15 fallback.
        // Without this, every photo got the no-beak constant (0.15) for
        // its head circle, which over-triggered .headFocus on ~most shots.
        let headRadiusFraction = FocusPointDetector.headRadiusFraction(
            beakVisibility: keypoints.beak.visibility,
            eye: bestEye,
            beak: (x: keypoints.beak.x, y: keypoints.beak.y)
        )

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
                    filePath: fileURL.path,
                    birdBbox: bird.bbox,
                    eyeCenter: bestEye,
                    headRadiusFraction: headRadiusFraction,
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
                headRadiusFraction: headRadiusFraction,
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
            bestEyeVisibility: keypoints.bestEyeVisibility,
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

    private static func prepareSharpness(
        rawReadLimiter: RawReadLimiter,
        rawConverter: RAWConverter,
        fileURL: URL,
        inferenceImage: CGImage,
        bird: BirdDetection,
        fallbackCrop: CGImage
    ) -> SharpnessPreparation {
        let source = rawReadLimiter.withPermit {
            rawConverter.decodeForSharpness(fileURL: fileURL)
        } ?? inferenceImage
        let crop = source.smartSquareBirdCrop(bbox: bird.bbox) ?? fallbackCrop
        let segmentationMask = birdCropAlignedSegMask(
            yoloMask: bird.mask,
            inferImage: source,
            bbox: bird.bbox,
            birdCropSize: crop.width
        )
        return SharpnessPreparation(
            birdCrop: crop,
            segmentationMask: segmentationMask,
            bboxSize: (
                width: Int((bird.bbox.width * CGFloat(source.width)).rounded()),
                height: Int((bird.bbox.height * CGFloat(source.height)).rounded())
            )
        )
    }

    private static func elapsedMs(since start: DispatchTime) -> String {
        String(format: "%.1f", elapsedMilliseconds(since: start))
    }

    private static func elapsedMilliseconds(since start: DispatchTime) -> Double {
        let ns = DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds
        return Double(ns) / 1_000_000
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

    /// Build a binary segmentation mask aligned with the bird crop produced
    /// by `image.smartSquareBirdCrop(bbox:)`. Each output byte is 1 iff the
    /// corresponding bird-crop pixel maps to a bird-pixel in the 160×160 YOLO
    /// seg mask, accounting for letterboxing in both directions.
    ///
    /// Parity reference: superpicky's
    /// `bird_crop_mask = bird_mask_orig[y_orig:y_orig+h, x_orig:x_orig+w]`
    /// (`core/photo_processor.py:1742`). The Python path nearest-neighbor
    /// upsamples the 160×160 YOLO mask to the original image resolution and
    /// slices by bbox; we sample per pixel here so we can reuse the existing
    /// `bird.mask` blob without an intermediate full-resolution buffer.
    ///
    /// Returns nil if mask data is malformed or the bird crop geometry is
    /// degenerate.
    static func birdCropAlignedSegMask(
        yoloMask: Data,
        inferImage: CGImage,
        bbox: CGRect,
        birdCropSize: Int,
        paddingRatio: CGFloat = 0.15
    ) -> [UInt8]? {
        guard !yoloMask.isEmpty, birdCropSize > 0 else { return nil }
        let maskSide = Int(Double(yoloMask.count).squareRoot().rounded())
        guard maskSide > 0, maskSide * maskSide == yoloMask.count else { return nil }

        let imgW = inferImage.width
        let imgH = inferImage.height
        guard imgW > 0, imgH > 0 else { return nil }

        // Replicate `smartSquareBirdCrop`'s integer geometry so we can map
        // bird-crop pixels back to inference-image pixels exactly.
        let px1 = Int((bbox.origin.x * CGFloat(imgW)).rounded(.down))
        let py1 = Int((bbox.origin.y * CGFloat(imgH)).rounded(.down))
        let px2 = Int(((bbox.origin.x + bbox.size.width)  * CGFloat(imgW)).rounded(.up))
        let py2 = Int(((bbox.origin.y + bbox.size.height) * CGFloat(imgH)).rounded(.up))
        let bboxW = px2 - px1, bboxH = py2 - py1
        guard bboxW > 0, bboxH > 0 else { return nil }
        let maxSide = max(bboxW, bboxH)
        let targetSide = Int(Double(maxSide) * (1.0 + Double(paddingRatio)))
        let cx = (px1 + px2) / 2, cy = (py1 + py2) / 2
        let half = targetSide / 2
        let cropX1 = max(0, cx - half), cropY1 = max(0, cy - half)
        let cropX2 = min(imgW, cx + half), cropY2 = min(imgH, cy + half)
        let cropW = cropX2 - cropX1, cropH = cropY2 - cropY1
        guard cropW > 0, cropH > 0 else { return nil }
        let sqSize = max(cropW, cropH)
        // Sanity-check against the actual CGImage we got back from
        // smartSquareBirdCrop — drift here would silently desynchronize the
        // mask from the pixels.
        guard sqSize == birdCropSize else { return nil }
        let offX = (sqSize - cropW) / 2, offY = (sqSize - cropH) / 2

        // YOLO letterbox params: inference image is scaled to fit a
        // `yoloInputSize × yoloInputSize` square with symmetric padding,
        // and the mask is at `maskSide` resolution (160×160 by default,
        // i.e. yoloInputSize/4).
        let yoloSize = Float(InferenceConstants.yoloInputSize)
        let origW = Float(imgW), origH = Float(imgH)
        let scale = min(yoloSize / origW, yoloSize / origH)
        let padLeft = (yoloSize - origW * scale) / 2
        let padTop  = (yoloSize - origH * scale) / 2
        let maskScale = Float(maskSide) / yoloSize

        var out = [UInt8](repeating: 0, count: sqSize * sqSize)
        yoloMask.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let mask = raw.bindMemory(to: UInt8.self)
            for y in 0..<sqSize {
                let inCanvasY = y - offY
                if inCanvasY < 0 || inCanvasY >= cropH { continue }
                let infY = Float(cropY1 + inCanvasY)
                let yoloY = infY * scale + padTop
                let my = Int((yoloY * maskScale).rounded(.down))
                guard my >= 0, my < maskSide else { continue }
                let mRow = my * maskSide
                let outRow = y * sqSize
                for x in 0..<sqSize {
                    let inCanvasX = x - offX
                    if inCanvasX < 0 || inCanvasX >= cropW { continue }
                    let infX = Float(cropX1 + inCanvasX)
                    let yoloX = infX * scale + padLeft
                    let mx = Int((yoloX * maskScale).rounded(.down))
                    if mx >= 0, mx < maskSide {
                        out[outRow + x] = mask[mRow + mx]
                    }
                }
            }
        }
        return out
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
