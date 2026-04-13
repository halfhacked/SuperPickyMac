import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import SuperPicky

/// BDD tests for the folder processing flow.
/// Tests the full pipeline: scan folder → detect → rate → save to DB.
@Suite struct ProcessingFlowTests {

    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func createTestJPEG(at url: URL) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 100, height: 100,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let image = context.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - Scenario: Process empty folder

    @Test func emptyFolderProducesNoResults() async throws {
        let tempDir = try makeTempDir()

        let mockClient = StubInferenceClient()
        let pipeline = PipelineCoordinator(inferenceClient: mockClient)
        let config = RatingEngine.Config(sharpnessThreshold: 380, aestheticsThreshold: 4.8)

        await pipeline.process(folder: tempDir, ratingConfig: config, exposureEnabled: false, exposureThreshold: 0.10)

        let db = try ReportDatabase(folderPath: tempDir)
        let photos = try db.fetchAllPhotos()
        #expect(photos.isEmpty)
        #expect(pipeline.totalCount == 0)
        #expect(pipeline.processedCount == 0)
    }

    // MARK: - Scenario: Process folder with photos, no birds detected

    @Test func noBirdsDetectedAllRatedMinusOne() async throws {
        let tempDir = try makeTempDir()
        for i in 0..<3 {
            createTestJPEG(at: tempDir.appendingPathComponent("IMG_\(i).jpg"))
        }

        // Mock returns no birds
        let mockClient = StubInferenceClient()
        let pipeline = PipelineCoordinator(inferenceClient: mockClient)
        let config = RatingEngine.Config(sharpnessThreshold: 380, aestheticsThreshold: 4.8)

        await pipeline.process(folder: tempDir, ratingConfig: config, exposureEnabled: false, exposureThreshold: 0.10)

        let db = try ReportDatabase(folderPath: tempDir)
        let photos = try db.fetchAllPhotos()
        #expect(photos.count == 3)
        for photo in photos {
            #expect(photo.starRating == -1)
        }
    }

    // MARK: - Scenario: Process folder with birds, get star ratings

    @Test func birdsDetectedAndRated() async throws {
        let tempDir = try makeTempDir()
        createTestJPEG(at: tempDir.appendingPathComponent("bird1.jpg"))
        createTestJPEG(at: tempDir.appendingPathComponent("bird2.jpg"))

        // Mock returns a bird with good scores
        var mockClient = StubInferenceClient()
        mockClient.detectResult = DetectionResult(birds: [
            BirdDetection(
                bbox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
                confidence: 0.95,
                mask: Data()
            )
        ])
        mockClient.aestheticsResult = AestheticsResponse(score: 6.0, distribution: [])

        let pipeline = PipelineCoordinator(inferenceClient: mockClient)
        let config = RatingEngine.Config(sharpnessThreshold: 380, aestheticsThreshold: 4.8)

        await pipeline.process(folder: tempDir, ratingConfig: config, exposureEnabled: false, exposureThreshold: 0.10)

        let db = try ReportDatabase(folderPath: tempDir)
        let photos = try db.fetchAllPhotos()
        #expect(photos.count == 2)
        for photo in photos {
            #expect(photo.starRating >= 1)
            #expect(photo.aestheticsScore == 6.0)
            #expect(photo.birdConfidence == 0.95)
        }
    }

    // MARK: - Scenario: Process folder with auto-organize


    // MARK: - Scenario: Processing is cancellable

    @Test func cancellationStopsProcessing() async throws {
        let tempDir = try makeTempDir()
        for i in 0..<10 {
            createTestJPEG(at: tempDir.appendingPathComponent("IMG_\(i).jpg"))
        }

        // Slow mock that sleeps per request
        let mockClient = SlowInferenceClient()
        let pipeline = PipelineCoordinator(inferenceClient: mockClient)
        let config = RatingEngine.Config(sharpnessThreshold: 380, aestheticsThreshold: 4.8)

        let task = Task {
            await pipeline.process(folder: tempDir, ratingConfig: config, exposureEnabled: false, exposureThreshold: 0.10)
        }

        // Let it start, then cancel
        try await Task.sleep(for: .milliseconds(200))
        task.cancel()
        try await Task.sleep(for: .milliseconds(100))

        // Should not have processed all 10
        #expect(pipeline.processedCount < 10)
    }

    // MARK: - Scenario: Database persists results per folder

    @Test func databasePersistedInFolder() async throws {
        let tempDir = try makeTempDir()
        createTestJPEG(at: tempDir.appendingPathComponent("test.jpg"))

        let mockClient = StubInferenceClient()
        let pipeline = PipelineCoordinator(inferenceClient: mockClient)
        let config = RatingEngine.Config(sharpnessThreshold: 380, aestheticsThreshold: 4.8)

        await pipeline.process(folder: tempDir, ratingConfig: config, exposureEnabled: false, exposureThreshold: 0.10)

        // .report.db should exist in the folder
        let dbPath = tempDir.appendingPathComponent(".report.db").path
        #expect(FileManager.default.fileExists(atPath: dbPath))

        // Re-open the DB and verify data persisted
        let db = try ReportDatabase(folderPath: tempDir)
        let photos = try db.fetchAllPhotos()
        #expect(photos.count == 1)
        #expect(photos[0].filename == "test.jpg")
    }
}

// MARK: - Test Doubles

private struct StubInferenceClient: InferenceClient {
    var detectResult = DetectionResult(birds: [])
    var aestheticsResult = AestheticsResponse(score: 5.0, distribution: [])
    var keypointResult = KeypointResult(
        leftEye: Keypoint(x: 0.4, y: 0.3, visibility: 0.9),
        rightEye: Keypoint(x: 0.6, y: 0.3, visibility: 0.9),
        beak: Keypoint(x: 0.5, y: 0.5, visibility: 0.95)
    )

    func detect(image: CGImage) async throws -> DetectionResult { detectResult }
    func aesthetics(image: CGImage) async throws -> AestheticsResponse { aestheticsResult }
    func keypoints(image: CGImage) async throws -> KeypointResult { keypointResult }
    func flight(image: CGImage) async throws -> FlightResult { FlightResult(isFlying: false, confidence: 0.1) }
    func identify(image: CGImage, topK: Int, temperature: Float, latitude: Double?, longitude: Double?) async throws -> [SpeciesMatch] { [] }
    func healthCheck() async throws -> ServerHealth { ServerHealth(status: "ready", modelsLoaded: [], device: "cpu", version: "1.0.0") }
}

private struct SlowInferenceClient: InferenceClient {
    func detect(image: CGImage) async throws -> DetectionResult {
        try await Task.sleep(for: .milliseconds(100))
        return DetectionResult(birds: [])
    }
    func aesthetics(image: CGImage) async throws -> AestheticsResponse { AestheticsResponse(score: 5.0, distribution: []) }
    func keypoints(image: CGImage) async throws -> KeypointResult {
        KeypointResult(leftEye: Keypoint(x: 0.5, y: 0.5, visibility: 0.9),
                       rightEye: Keypoint(x: 0.5, y: 0.5, visibility: 0.9),
                       beak: Keypoint(x: 0.5, y: 0.5, visibility: 0.9))
    }
    func flight(image: CGImage) async throws -> FlightResult { FlightResult(isFlying: false, confidence: 0.1) }
    func identify(image: CGImage, topK: Int, temperature: Float, latitude: Double?, longitude: Double?) async throws -> [SpeciesMatch] { [] }
    func healthCheck() async throws -> ServerHealth { ServerHealth(status: "ready", modelsLoaded: [], device: "cpu", version: "1.0.0") }
}
