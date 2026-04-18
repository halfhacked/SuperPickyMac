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

    // Real species results from preen dry-run on test-photos.
    private static let speciesByFile: [String: Fixture] = [
        "DSC00001": Fixture(scientific: "Haliaeetus leucocephalus", common: "Bald Eagle",         confidence: 0.98, cn: "白头海雕", pinyin: "baitouhaidiao", ebird: "baleag"),
        "DSC00003": Fixture(scientific: "Haliaeetus leucocephalus", common: "Bald Eagle",         confidence: 0.98, cn: "白头海雕", pinyin: "baitouhaidiao", ebird: "baleag"),
        "DSC00005": Fixture(scientific: "Haliaeetus leucocephalus", common: "Bald Eagle",         confidence: 0.97, cn: "白头海雕", pinyin: "baitouhaidiao", ebird: "baleag"),
        "DSC00006": Fixture(scientific: "Haliaeetus leucocephalus", common: "Bald Eagle",         confidence: 0.98, cn: "白头海雕", pinyin: "baitouhaidiao", ebird: "baleag"),
        "DSC00007": Fixture(scientific: "Haliaeetus leucocephalus", common: "Bald Eagle",         confidence: 0.97, cn: "白头海雕", pinyin: "baitouhaidiao", ebird: "baleag"),
        "DSC00008": Fixture(scientific: "Haliaeetus leucocephalus", common: "Bald Eagle",         confidence: 0.97, cn: "白头海雕", pinyin: "baitouhaidiao", ebird: "baleag"),
        "DSC00017": Fixture(scientific: "Haliaeetus leucocephalus", common: "Bald Eagle",         confidence: 0.99, cn: "白头海雕", pinyin: "baitouhaidiao", ebird: "baleag"),
        "DSC00022": Fixture(scientific: "Haliaeetus leucocephalus", common: "Bald Eagle",         confidence: 0.96, cn: "白头海雕", pinyin: "baitouhaidiao", ebird: "baleag"),
        // DSC00029: bird detected, not identified
        // DSC00035: no birds
        "DSC00037": Fixture(scientific: "Gavia immer",              common: "Common Loon",        confidence: 0.81, cn: "普通潜鸟", pinyin: "putongqianniao", ebird: "comloo"),
        "DSC00045": Fixture(scientific: "Bucephala islandica",      common: "Barrow's Goldeneye", confidence: 0.98, cn: "巴氏鹊鸭", pinyin: "bashiqueya",     ebird: "bargol"),
        "DSC00046": Fixture(scientific: "Bucephala islandica",      common: "Barrow's Goldeneye", confidence: 0.98, cn: "巴氏鹊鸭", pinyin: "bashiqueya",     ebird: "bargol"),
        "DSC00050": Fixture(scientific: "Gavia immer",              common: "Common Loon",        confidence: 0.95, cn: "普通潜鸟", pinyin: "putongqianniao", ebird: "comloo"),
        "DSC00090": Fixture(scientific: "Gavia immer",              common: "Common Loon",        confidence: 0.95, cn: "普通潜鸟", pinyin: "putongqianniao", ebird: "comloo"),
        "DSC00168": Fixture(scientific: "Cepphus columba",          common: "Pigeon Guillemot",   confidence: 1.0,  cn: "海鸽",     pinyin: "haige",          ebird: "piggui"),
        "DSC00169": Fixture(scientific: "Cepphus columba",          common: "Pigeon Guillemot",   confidence: 1.0,  cn: "海鸽",     pinyin: "haige",          ebird: "piggui"),
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

        if stem == "DSC00035" {
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
