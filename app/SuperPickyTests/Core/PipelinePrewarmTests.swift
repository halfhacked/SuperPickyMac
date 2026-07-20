import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import SuperPicky
import SuperPickyInference

/// Captures `prewarmGPSCells` calls so tests can assert the pipeline
/// forwards unique cells from the pre-pass.
final class RecordingInferenceClient: InferenceClient, @unchecked Sendable {
    var identifyBirds: [BirdDetection] = []
    private let lock = NSLock()
    private var _prewarmCalls: [[(lat: Double, lon: Double)]] = []
    private var _identifiedPaths: [String] = []

    var prewarmCalls: [[(lat: Double, lon: Double)]] {
        lock.withLock { _prewarmCalls }
    }
    var identifiedPaths: [String] {
        lock.withLock { _identifiedPaths }
    }

    func detect(image: CGImage) async throws -> DetectionResult {
        DetectionResult(birds: [])
    }
    func aesthetics(image: CGImage) async throws -> AestheticsResponse {
        AestheticsResponse(score: 5.0, distribution: [])
    }
    func keypoints(image: CGImage) async throws -> KeypointResult {
        KeypointResult(
            leftEye: Keypoint(x: 0.4, y: 0.3, visibility: 0.9),
            rightEye: Keypoint(x: 0.6, y: 0.3, visibility: 0.9),
            beak: Keypoint(x: 0.5, y: 0.5, visibility: 0.95)
        )
    }
    func flight(image: CGImage) async throws -> FlightResult {
        FlightResult(isFlying: false, confidence: 0.1)
    }
    func identify(filePath: String, topK: Int, preDecodedImage: CGImage?, preGPS: (lat: Double, lon: Double)?) async throws -> IdentifyResponse {
        lock.withLock { _identifiedPaths.append(filePath) }
        return IdentifyResponse(species: [], birds: identifyBirds, totalDetected: identifyBirds.count)
    }
    func prewarmGPSCells(_ cells: [(lat: Double, lon: Double)]) async {
        lock.withLock { _prewarmCalls.append(cells) }
    }
}

@Suite struct PipelinePrewarmTests {
    private func createJPEG(at url: URL, gps: (lat: Double, lon: Double)?) {
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let ctx = CGContext(
            data: nil, width: 16, height: 16,
            bitsPerComponent: 8, bytesPerRow: 0, space: cs,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        ctx.setFillColor(gray: 0.5, alpha: 1)
        ctx.fill(CGRect(x: 0, y: 0, width: 16, height: 16))
        let image = ctx.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        var props: [String: Any] = [:]
        props[kCGImagePropertyExifDictionary as String] = [
            "DateTimeOriginal": "2024:03:15 14:30:22"
        ]
        if let gps {
            props[kCGImagePropertyGPSDictionary as String] = [
                kCGImagePropertyGPSLatitude as String: abs(gps.lat),
                kCGImagePropertyGPSLatitudeRef as String: gps.lat >= 0 ? "N" : "S",
                kCGImagePropertyGPSLongitude as String: abs(gps.lon),
                kCGImagePropertyGPSLongitudeRef as String: gps.lon >= 0 ? "E" : "W",
            ]
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private func tempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("PipelinePrewarm_\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func dedupesByGPSCellAndSkipsFilesWithoutGPS() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }

        // Two photos in the same 0.1° cell (Seattle), one in a different
        // cell (Ocean Shores), and one with no GPS.
        createJPEG(at: dir.appendingPathComponent("a.jpg"), gps: (47.6062, -122.3321))
        createJPEG(at: dir.appendingPathComponent("b.jpg"), gps: (47.6100, -122.3400))
        createJPEG(at: dir.appendingPathComponent("c.jpg"), gps: (46.9781, -124.1579))
        createJPEG(at: dir.appendingPathComponent("d.jpg"), gps: nil)

        let client = RecordingInferenceClient()
        let pipeline = PipelineCoordinator(inferenceClient: client)
        let config = RatingEngine.Config(sharpnessThreshold: 380, aestheticsThreshold: 4.8)
        await pipeline.process(folder: dir, ratingConfig: config,
                               exposureEnabled: false, exposureThreshold: 0.10)

        #expect(client.prewarmCalls.count == 1)
        let cells = client.prewarmCalls[0]
        #expect(cells.count == 2)
        // Cells should be Seattle + Ocean Shores, deduped by 0.1° grid.
        let keys = Set(cells.map { GPSCell.key(lat: $0.lat, lon: $0.lon) })
        #expect(keys.contains(GPSCell.key(lat: 47.6062, lon: -122.3321)))
        #expect(keys.contains(GPSCell.key(lat: 46.9781, lon: -124.1579)))
    }

    @Test func emptyCellsWhenNoPhotoHasGPS() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        createJPEG(at: dir.appendingPathComponent("nogps.jpg"), gps: nil)

        let client = RecordingInferenceClient()
        let pipeline = PipelineCoordinator(inferenceClient: client)
        let config = RatingEngine.Config(sharpnessThreshold: 380, aestheticsThreshold: 4.8)
        await pipeline.process(folder: dir, ratingConfig: config,
                               exposureEnabled: false, exposureThreshold: 0.10)

        #expect(client.prewarmCalls.count == 1)
        #expect(client.prewarmCalls[0].isEmpty)
    }

    @Test func resumePrepassesAndIdentifiesOnlyPendingFiles() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        let existingURL = dir.appendingPathComponent("existing.jpg")
        let pendingURL = dir.appendingPathComponent("pending.jpg")
        createJPEG(at: existingURL, gps: (47.6062, -122.3321))
        createJPEG(at: pendingURL, gps: (46.9781, -124.1579))

        let scanned = try DirectoryScanner().scan(folder: dir)
        let scannedExisting = try #require(
            scanned.first { $0.lastPathComponent == existingURL.lastPathComponent }
        )
        let scannedPending = try #require(
            scanned.first { $0.lastPathComponent == pendingURL.lastPathComponent }
        )
        let db = try ReportDatabase(folderPath: dir)
        var existing = Photo(
            filename: scannedExisting.lastPathComponent,
            filePath: scannedExisting.path,
            folderPath: dir.path
        )
        try db.save(&existing)

        let client = RecordingInferenceClient()
        let pipeline = PipelineCoordinator(inferenceClient: client)
        let config = RatingEngine.Config(sharpnessThreshold: 380, aestheticsThreshold: 4.8)
        await pipeline.process(
            folder: dir, ratingConfig: config,
            exposureEnabled: false, exposureThreshold: 0.10
        )

        #expect(pipeline.totalCount == 2)
        #expect(pipeline.processedCount == 2)
        #expect(client.identifiedPaths == [scannedPending.path])
        #expect(client.prewarmCalls.count == 1)
        let warmedKeys = Set(client.prewarmCalls[0].map {
            GPSCell.key(lat: $0.lat, lon: $0.lon)
        })
        #expect(warmedKeys == [
            GPSCell.key(lat: 46.9781, lon: -124.1579)
        ])
    }

    @Test func resumePreservesExistingPhotoAsBurstBoundary() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for name in ["a.jpg", "b.jpg", "c.jpg"] {
            createJPEG(at: dir.appendingPathComponent(name), gps: nil)
        }
        let scanned = try DirectoryScanner().scan(folder: dir)
        let existingURL = try #require(
            scanned.first { $0.lastPathComponent == "b.jpg" }
        )
        let properties = try #require(
            ImageProperties.load(filePath: existingURL.path)
        )
        let captureTimestamp = try #require(
            BurstDetector.parseTimestamp(from: properties)
        )

        let db = try ReportDatabase(folderPath: dir)
        var existing = Photo(
            filename: existingURL.lastPathComponent,
            filePath: existingURL.path,
            folderPath: dir.path,
            dateCreated: Date(timeIntervalSince1970: captureTimestamp)
        )
        try db.save(&existing)

        let client = RecordingInferenceClient()
        client.identifyBirds = [
            BirdDetection(
                bbox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
                confidence: 0.95,
                mask: Data()
            )
        ]
        let pipeline = PipelineCoordinator(inferenceClient: client)
        let config = RatingEngine.Config(
            sharpnessThreshold: 100, aestheticsThreshold: 2
        )
        await pipeline.process(
            folder: dir, ratingConfig: config,
            exposureEnabled: false, exposureThreshold: 0.10
        )

        let photos = try db.fetchAllPhotos()
        let pending = photos.filter { $0.filename != "b.jpg" }
        #expect(pending.count == 2)
        #expect(pending.allSatisfy { $0.burstGroupID == nil })
    }

    @Test func coldRunPrewarmsMetadataInIncrementalBatches() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        for (index, gps) in [
            (47.6062, -122.3321),
            (46.9781, -124.1579),
            (45.5152, -122.6784),
        ].enumerated() {
            createJPEG(
                at: dir.appendingPathComponent("\(index).jpg"),
                gps: gps
            )
        }

        let client = RecordingInferenceClient()
        let pipeline = PipelineCoordinator(
            inferenceClient: client,
            initialMetadataBatchSize: 1,
            metadataBatchSize: 1
        )
        let config = RatingEngine.Config(
            sharpnessThreshold: 380,
            aestheticsThreshold: 4.8
        )
        await pipeline.process(
            folder: dir,
            ratingConfig: config,
            exposureEnabled: false,
            exposureThreshold: 0.10
        )

        #expect(client.prewarmCalls.count == 3)
        #expect(client.identifiedPaths.count == 3)
    }

    @Test func burstCanSpanMetadataBatchBoundary() async throws {
        let dir = try tempDir()
        defer { try? FileManager.default.removeItem(at: dir) }
        createJPEG(at: dir.appendingPathComponent("a.jpg"), gps: nil)
        createJPEG(at: dir.appendingPathComponent("b.jpg"), gps: nil)

        let client = RecordingInferenceClient()
        client.identifyBirds = [
            BirdDetection(
                bbox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
                confidence: 0.95,
                mask: Data()
            )
        ]
        let pipeline = PipelineCoordinator(
            inferenceClient: client,
            initialMetadataBatchSize: 1,
            metadataBatchSize: 1
        )
        let config = RatingEngine.Config(
            sharpnessThreshold: 100,
            aestheticsThreshold: 2
        )
        await pipeline.process(
            folder: dir,
            ratingConfig: config,
            exposureEnabled: false,
            exposureThreshold: 0.10
        )

        let photos = try ReportDatabase(folderPath: dir).fetchAllPhotos()
        #expect(photos.count == 2)
        #expect(photos[0].burstGroupID != nil)
        #expect(photos[0].burstGroupID == photos[1].burstGroupID)
        #expect(photos.filter(\.isBurstBest).count == 1)
    }
}

@Suite struct PhotoApplyLocationTests {
    @Test func applyLocationCopiesAllFields() {
        var photo = Photo(filename: "a.jpg", filePath: "/tmp/a.jpg", folderPath: "/tmp")
        let loc = LocationInfo(
            city: "Seattle", state: "WA", country: "United States",
            countryCode: "US", sublocation: "Downtown"
        )
        photo.applyLocation(loc)
        #expect(photo.locationCity == "Seattle")
        #expect(photo.locationState == "WA")
        #expect(photo.locationCountry == "United States")
        #expect(photo.locationCountryCode == "US")
        #expect(photo.locationSublocation == "Downtown")
    }

    @Test func applyLocationPreservesNilFields() {
        var photo = Photo(filename: "a.jpg", filePath: "/tmp/a.jpg", folderPath: "/tmp")
        let loc = LocationInfo(
            city: nil, state: "CA", country: nil, countryCode: "US", sublocation: nil
        )
        photo.applyLocation(loc)
        #expect(photo.locationCity == nil)
        #expect(photo.locationState == "CA")
        #expect(photo.locationCountry == nil)
        #expect(photo.locationCountryCode == "US")
        #expect(photo.locationSublocation == nil)
    }
}
