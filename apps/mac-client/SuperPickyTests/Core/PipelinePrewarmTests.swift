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

    var prewarmCalls: [[(lat: Double, lon: Double)]] {
        lock.lock(); defer { lock.unlock() }
        return _prewarmCalls
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
        IdentifyResponse(species: [], birds: identifyBirds, totalDetected: identifyBirds.count)
    }
    func prewarmGPSCells(_ cells: [(lat: Double, lon: Double)]) async {
        lock.lock(); defer { lock.unlock() }
        _prewarmCalls.append(cells)
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
