import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import SuperPicky

struct MockInferenceClient: InferenceClient {
    var detectResult: DetectionResult = DetectionResult(birds: [])
    var aestheticsResult: AestheticsResponse = AestheticsResponse(score: 5.0, distribution: [])
    var keypointResult: KeypointResult = KeypointResult(
        leftEye: Keypoint(x: 0.4, y: 0.3, visibility: 0.9),
        rightEye: Keypoint(x: 0.6, y: 0.3, visibility: 0.9),
        beak: Keypoint(x: 0.5, y: 0.5, visibility: 0.95)
    )
    var flightResult: FlightResult = FlightResult(isFlying: false, confidence: 0.1)

    func detect(image: CGImage) async throws -> DetectionResult { detectResult }
    func aesthetics(image: CGImage) async throws -> AestheticsResponse { aestheticsResult }
    func keypoints(image: CGImage) async throws -> KeypointResult { keypointResult }
    func flight(image: CGImage) async throws -> FlightResult { flightResult }
    func identify(image: CGImage, topK: Int, temperature: Float) async throws -> [SpeciesMatch] { [] }
    func healthCheck() async throws -> ServerHealth {
        ServerHealth(status: "ready", modelsLoaded: [], device: "cpu", version: "1.0.0")
    }
}

@Suite struct PipelineCoordinatorTests {
    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    func createTestJPEG(at url: URL) {
        // Create a minimal valid JPEG-like file (1x1 pixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(data: nil, width: 100, height: 100, bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)!
        let image = context.makeImage()!

        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    @Test func noBirdDetectedRatesMinusOne() async throws {
        let tempDir = try makeTempDir()
        let jpegURL = tempDir.appendingPathComponent("test.jpg")
        createTestJPEG(at: jpegURL)

        let mockClient = MockInferenceClient()
        let config = RatingEngine.Config(sharpnessThreshold: 380, aestheticsThreshold: 4.8)
        let pipeline = PipelineCoordinator(inferenceClient: mockClient)

        await pipeline.process(folder: tempDir, ratingConfig: config, exposureEnabled: true, exposureThreshold: 0.10)

        let db = try ReportDatabase(folderPath: tempDir)
        let photos = try db.fetchAllPhotos()
        #expect(photos.count == 1)
        #expect(photos[0].starRating == -1)
    }

    @Test func birdDetectedRatesCorrectly() async throws {
        let tempDir = try makeTempDir()
        let jpegURL = tempDir.appendingPathComponent("bird.jpg")
        createTestJPEG(at: jpegURL)

        var mockClient = MockInferenceClient()
        mockClient.detectResult = DetectionResult(birds: [
            BirdDetection(bbox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5), confidence: 0.95, mask: Data())
        ])
        mockClient.aestheticsResult = AestheticsResponse(score: 6.0, distribution: [])

        let config = RatingEngine.Config(sharpnessThreshold: 380, aestheticsThreshold: 4.8)
        let pipeline = PipelineCoordinator(inferenceClient: mockClient)

        await pipeline.process(folder: tempDir, ratingConfig: config, exposureEnabled: false, exposureThreshold: 0.10)

        let db = try ReportDatabase(folderPath: tempDir)
        let photos = try db.fetchAllPhotos()
        #expect(photos.count == 1)
        #expect(photos[0].starRating >= 1)
        #expect(photos[0].aestheticsScore == 6.0)
    }

    @Test func progressTracking() async throws {
        let tempDir = try makeTempDir()
        for i in 0..<3 {
            let url = tempDir.appendingPathComponent("IMG_\(i).jpg")
            createTestJPEG(at: url)
        }

        let mockClient = MockInferenceClient()
        let config = RatingEngine.Config(sharpnessThreshold: 380, aestheticsThreshold: 4.8)
        let pipeline = PipelineCoordinator(inferenceClient: mockClient)

        await pipeline.process(folder: tempDir, ratingConfig: config, exposureEnabled: false, exposureThreshold: 0.10)

        #expect(pipeline.processedCount == 3)
        #expect(pipeline.totalCount == 3)
        #expect(pipeline.isProcessing == false)
    }
}
