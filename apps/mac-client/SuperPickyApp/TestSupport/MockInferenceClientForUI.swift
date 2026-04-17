import Foundation
import CoreGraphics

// Test infrastructure — used by XCUITests via TEST_MODE environment variable
struct MockInferenceClientForUI: InferenceClient {
    func detect(image: CGImage) async throws -> DetectionResult { DetectionResult(birds: []) }
    func aesthetics(image: CGImage) async throws -> AestheticsResponse {
        // Vary score slightly based on image dimensions for diversity
        let score = 4.5 + Float(image.width % 3)
        return AestheticsResponse(score: score, distribution: [])
    }
    func keypoints(image: CGImage) async throws -> KeypointResult {
        KeypointResult(leftEye: Keypoint(x: 0.4, y: 0.3, visibility: 0.85),
                       rightEye: Keypoint(x: 0.6, y: 0.3, visibility: 0.9),
                       beak: Keypoint(x: 0.5, y: 0.5, visibility: 0.95))
    }
    func flight(image: CGImage) async throws -> FlightResult {
        // Some photos "fly" based on width parity
        FlightResult(isFlying: image.width % 5 == 0, confidence: 0.8)
    }
    // Real species results from preen dry-run on test-photos
    private static let speciesByFile: [String: (String, String, Float, String, String)] = [
        // (scientific, common, confidence, cn, pinyin)
        "DSC00001": ("Haliaeetus leucocephalus", "Bald Eagle", 0.98, "白头海雕", "baitouhaidiao"),
        "DSC00003": ("Haliaeetus leucocephalus", "Bald Eagle", 0.98, "白头海雕", "baitouhaidiao"),
        "DSC00005": ("Haliaeetus leucocephalus", "Bald Eagle", 0.97, "白头海雕", "baitouhaidiao"),
        "DSC00006": ("Haliaeetus leucocephalus", "Bald Eagle", 0.98, "白头海雕", "baitouhaidiao"),
        "DSC00007": ("Haliaeetus leucocephalus", "Bald Eagle", 0.97, "白头海雕", "baitouhaidiao"),
        "DSC00008": ("Haliaeetus leucocephalus", "Bald Eagle", 0.97, "白头海雕", "baitouhaidiao"),
        "DSC00017": ("Haliaeetus leucocephalus", "Bald Eagle", 0.99, "白头海雕", "baitouhaidiao"),
        "DSC00022": ("Haliaeetus leucocephalus", "Bald Eagle", 0.96, "白头海雕", "baitouhaidiao"),
        // DSC00029: bird detected, not identified
        // DSC00035: no birds
        "DSC00037": ("Gavia immer", "Common Loon", 0.81, "普通潜鸟", "putongqianniao"),
        "DSC00045": ("Bucephala islandica", "Barrow's Goldeneye", 0.98, "巴氏鹊鸭", "bashiqueya"),
        "DSC00046": ("Bucephala islandica", "Barrow's Goldeneye", 0.98, "巴氏鹊鸭", "bashiqueya"),
        "DSC00050": ("Gavia immer", "Common Loon", 0.95, "普通潜鸟", "putongqianniao"),
        "DSC00090": ("Gavia immer", "Common Loon", 0.95, "普通潜鸟", "putongqianniao"),
        "DSC00168": ("Cepphus columba", "Pigeon Guillemot", 1.0, "海鸽", "haige"),
        "DSC00169": ("Cepphus columba", "Pigeon Guillemot", 1.0, "海鸽", "haige"),
    ]

    func identify(filePath: String, topK: Int, preDecodedImage: CGImage?, preGPS: (lat: Double, lon: Double)?) async throws -> IdentifyResponse {
        let filename = (filePath as NSString).lastPathComponent
        let stem = (filename as NSString).deletingPathExtension

        // DSC00035: no birds at all
        if stem == "DSC00035" {
            return IdentifyResponse(species: [], birds: nil, totalDetected: 0)
        }

        let bird = BirdDetection(
            bbox: CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7),
            confidence: 0.92,
            mask: Data()
        )

        // DSC00029: bird detected but not identified
        guard let sp = Self.speciesByFile[stem] else {
            return IdentifyResponse(species: [], birds: [bird], totalDetected: 1)
        }

        let species = SpeciesMatch(
            scientificName: sp.0,
            commonName: sp.1,
            confidence: sp.2,
            cnName: sp.3,
            pinyin: sp.4,
            thresholdUsed: "mock"
        )
        return IdentifyResponse(species: [species], birds: [bird], totalDetected: 1)
    }
}
