import Foundation
import CoreGraphics

// Test infrastructure — used by XCUITests via TEST_MODE environment variable
struct MockInferenceClientForUI: InferenceClient {
    func detect(image: CGImage) async throws -> DetectionResult { DetectionResult(birds: []) }
    func aesthetics(image: CGImage) async throws -> AestheticsResponse {
        let score = 4.5 + Float(image.width % 3)
        return AestheticsResponse(score: score, distribution: [])
    }
    func keypoints(image: CGImage) async throws -> KeypointResult {
        KeypointResult(leftEye: Keypoint(x: 0.4, y: 0.3, visibility: 0.85),
                       rightEye: Keypoint(x: 0.6, y: 0.3, visibility: 0.9),
                       beak: Keypoint(x: 0.5, y: 0.5, visibility: 0.95))
    }
    func flight(image: CGImage) async throws -> FlightResult {
        FlightResult(isFlying: image.width % 5 == 0, confidence: 0.8)
    }

    private struct Fixture {
        let scientific: String
        let common: String
        let confidence: Float
        let cn: String
        let pinyin: String
        let ebird: String
    }

    // Mock species fixtures keyed by filename stem.
    // Files not in the map return "bird, no species" (tests the unidentified-bird path).
    private static let speciesByFile: [String: Fixture] = [
        // Anna's Hummingbird — burst A1 (09176-80), burst A2 (09199-202), singles (09407, 09660)
        "DSC09176": Fixture(scientific: "Calypte anna",             common: "Anna's Hummingbird", confidence: 0.97, cn: "安娜蜂鸟", pinyin: "annafengniao",   ebird: "annhum"),
        "DSC09177": Fixture(scientific: "Calypte anna",             common: "Anna's Hummingbird", confidence: 0.98, cn: "安娜蜂鸟", pinyin: "annafengniao",   ebird: "annhum"),
        "DSC09178": Fixture(scientific: "Calypte anna",             common: "Anna's Hummingbird", confidence: 0.98, cn: "安娜蜂鸟", pinyin: "annafengniao",   ebird: "annhum"),
        "DSC09179": Fixture(scientific: "Calypte anna",             common: "Anna's Hummingbird", confidence: 0.97, cn: "安娜蜂鸟", pinyin: "annafengniao",   ebird: "annhum"),
        "DSC09180": Fixture(scientific: "Calypte anna",             common: "Anna's Hummingbird", confidence: 0.98, cn: "安娜蜂鸟", pinyin: "annafengniao",   ebird: "annhum"),
        "DSC09199": Fixture(scientific: "Calypte anna",             common: "Anna's Hummingbird", confidence: 0.96, cn: "安娜蜂鸟", pinyin: "annafengniao",   ebird: "annhum"),
        "DSC09200": Fixture(scientific: "Calypte anna",             common: "Anna's Hummingbird", confidence: 0.97, cn: "安娜蜂鸟", pinyin: "annafengniao",   ebird: "annhum"),
        "DSC09201": Fixture(scientific: "Calypte anna",             common: "Anna's Hummingbird", confidence: 0.97, cn: "安娜蜂鸟", pinyin: "annafengniao",   ebird: "annhum"),
        "DSC09202": Fixture(scientific: "Calypte anna",             common: "Anna's Hummingbird", confidence: 0.98, cn: "安娜蜂鸟", pinyin: "annafengniao",   ebird: "annhum"),
        "DSC09407": Fixture(scientific: "Calypte anna",             common: "Anna's Hummingbird", confidence: 0.95, cn: "安娜蜂鸟", pinyin: "annafengniao",   ebird: "annhum"),
        "DSC09660": Fixture(scientific: "Calypte anna",             common: "Anna's Hummingbird", confidence: 0.96, cn: "安娜蜂鸟", pinyin: "annafengniao",   ebird: "annhum"),
        // Bald Eagle — burst B1 (09968-72), burst B2 (09993-96), singles (09985, 09991)
        "DSC09968": Fixture(scientific: "Haliaeetus leucocephalus", common: "Bald Eagle",         confidence: 0.98, cn: "白头海雕", pinyin: "baitouhaidiao", ebird: "baleag"),
        "DSC09969": Fixture(scientific: "Haliaeetus leucocephalus", common: "Bald Eagle",         confidence: 0.98, cn: "白头海雕", pinyin: "baitouhaidiao", ebird: "baleag"),
        "DSC09970": Fixture(scientific: "Haliaeetus leucocephalus", common: "Bald Eagle",         confidence: 0.97, cn: "白头海雕", pinyin: "baitouhaidiao", ebird: "baleag"),
        "DSC09971": Fixture(scientific: "Haliaeetus leucocephalus", common: "Bald Eagle",         confidence: 0.98, cn: "白头海雕", pinyin: "baitouhaidiao", ebird: "baleag"),
        "DSC09972": Fixture(scientific: "Haliaeetus leucocephalus", common: "Bald Eagle",         confidence: 0.99, cn: "白头海雕", pinyin: "baitouhaidiao", ebird: "baleag"),
        "DSC09985": Fixture(scientific: "Haliaeetus leucocephalus", common: "Bald Eagle",         confidence: 0.96, cn: "白头海雕", pinyin: "baitouhaidiao", ebird: "baleag"),
        "DSC09991": Fixture(scientific: "Haliaeetus leucocephalus", common: "Bald Eagle",         confidence: 0.97, cn: "白头海雕", pinyin: "baitouhaidiao", ebird: "baleag"),
        "DSC09993": Fixture(scientific: "Haliaeetus leucocephalus", common: "Bald Eagle",         confidence: 0.98, cn: "白头海雕", pinyin: "baitouhaidiao", ebird: "baleag"),
        "DSC09994": Fixture(scientific: "Haliaeetus leucocephalus", common: "Bald Eagle",         confidence: 0.97, cn: "白头海雕", pinyin: "baitouhaidiao", ebird: "baleag"),
        "DSC09995": Fixture(scientific: "Haliaeetus leucocephalus", common: "Bald Eagle",         confidence: 0.98, cn: "白头海雕", pinyin: "baitouhaidiao", ebird: "baleag"),
        "DSC09996": Fixture(scientific: "Haliaeetus leucocephalus", common: "Bald Eagle",         confidence: 0.99, cn: "白头海雕", pinyin: "baitouhaidiao", ebird: "baleag"),
        // Remaining DSC09950-DSC09967 intentionally absent → bird detected but not identified
    ]

    // No bird detected at all (matches NULL birdConfidence in the source DB).
    private static let noBirdFiles: Set<String> = [
        "DSC09955", "DSC09960", "DSC09961", "DSC09962", "DSC09964", "DSC09967",
    ]

    // thresholdUsed "country" so the candidate rows render the "Region"
    // level label — exercises levelLabel(_:) in the edit panel.
    private static let nearMissPool: [SpeciesMatch] = [
        SpeciesMatch(scientificName: "Aquila chrysaetos", commonName: "Golden Eagle",
                     confidence: 0.12, cnName: "金雕", pinyin: "jindiao",
                     thresholdUsed: "country", ebirdCode: "goleag"),
        SpeciesMatch(scientificName: "Pandion haliaetus", commonName: "Osprey",
                     confidence: 0.06, cnName: "鹗", pinyin: "e",
                     thresholdUsed: "country", ebirdCode: "osprey"),
    ]

    func identify(filePath: String, topK: Int, preDecodedImage: CGImage?, preGPS: (lat: Double, lon: Double)?) async throws -> IdentifyResponse {
        let filename = (filePath as NSString).lastPathComponent
        let stem = (filename as NSString).deletingPathExtension

        if Self.noBirdFiles.contains(stem) {
            return IdentifyResponse(species: [], birds: nil, totalDetected: 0)
        }

        let bird = BirdDetection(
            bbox: CGRect(x: 0.2, y: 0.15, width: 0.6, height: 0.7),
            confidence: 0.92,
            mask: Data()
        )

        guard let fixture = Self.speciesByFile[stem] else {
            return IdentifyResponse(species: [], birds: [bird], totalDetected: 1)
        }

        let species = SpeciesMatch(
            scientificName: fixture.scientific,
            commonName: fixture.common,
            confidence: fixture.confidence,
            cnName: fixture.cn,
            pinyin: fixture.pinyin,
            thresholdUsed: "mock",
            ebirdCode: fixture.ebird
        )
        let top5 = [species] + Self.nearMissPool.filter { $0.scientificName != fixture.scientific }
        return IdentifyResponse(species: [species], birds: [bird], totalDetected: 1, top5: top5)
    }
}
