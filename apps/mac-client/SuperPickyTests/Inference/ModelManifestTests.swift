import Foundation
import Testing
@testable import SuperPickyInference

@Suite("ModelManifest")
struct ModelManifestTests {
    @Test("loadBundled returns a manifest with version 1")
    func loadBundledVersion() throws {
        let manifest = try ModelManifest.loadBundled()
        #expect(manifest.version == 1)
    }

    @Test("Bundled manifest lists all five CoreML models with SHA-256 + size")
    func bundledModels() throws {
        let manifest = try ModelManifest.loadBundled()
        let ids = Set(manifest.models.map(\.id))
        #expect(ids == [
            "flight-detector",
            "keypoint-detector",
            "yolo-bird-detector",
            "osea-classifier",
            "aesthetics-model",
        ])
        // SpeciesDatabase is bundled with the app, so it must NOT be in the
        // download manifest.
        #expect(!ids.contains("bird-reference-db"))
        // Every entry must have a non-empty sha256 and a positive sizeBytes so
        // the downloader can verify + report progress.
        for entry in manifest.models {
            #expect(entry.sha256.count == 64)
            #expect(entry.sizeBytes > 0)
        }
    }

    @Test("ModelEntry decodes from JSON with all required fields")
    func decodeEntry() throws {
        let json = """
        {
          "id": "test-model",
          "filename": "test.mlmodelc.zip",
          "url": "https://example.com/test.mlmodelc.zip",
          "sha256": "abc123",
          "sizeBytes": 1024,
          "installPath": "Models/test.mlmodelc"
        }
        """.data(using: .utf8)!
        let entry = try JSONDecoder().decode(ModelEntry.self, from: json)
        #expect(entry.id == "test-model")
        #expect(entry.filename == "test.mlmodelc.zip")
        #expect(entry.sizeBytes == 1024)
        #expect(entry.installPath == "Models/test.mlmodelc")
    }

    @Test("Manifest round-trips through JSON encode/decode")
    func roundTrip() throws {
        let original = ModelManifest(
            version: 1,
            models: [
                ModelEntry(
                    id: "m1", filename: "m1.zip",
                    url: URL(string: "https://x.com/m1.zip")!, sha256: "def",
                    sizeBytes: 2048, installPath: "Models/m1.mlmodelc"
                )
            ]
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ModelManifest.self, from: data)
        #expect(decoded.version == original.version)
        #expect(decoded.models.count == 1)
        #expect(decoded.models[0].id == "m1")
    }
}
