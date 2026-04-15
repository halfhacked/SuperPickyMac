import Foundation
import Testing
@testable import SuperPicky

@Suite("PipelineCoordinator databaseName parameter", .serialized)
struct PipelineCoordinatorDatabaseNameTests {
    @Test("ReportDatabase.init(folderPath:) defaults name to .report.db")
    func defaultDatabaseName() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spa-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        _ = try ReportDatabase(folderPath: tmpDir)
        let expectedURL = tmpDir.appendingPathComponent(".report.db")
        #expect(FileManager.default.fileExists(atPath: expectedURL.path))
    }

    @Test("ReportDatabase.init(folderPath:name:) uses the custom name")
    func customDatabaseName() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spa-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        _ = try ReportDatabase(folderPath: tmpDir, name: ".report-custom.db")
        let customURL = tmpDir.appendingPathComponent(".report-custom.db")
        let defaultURL = tmpDir.appendingPathComponent(".report.db")
        #expect(FileManager.default.fileExists(atPath: customURL.path))
        #expect(!FileManager.default.fileExists(atPath: defaultURL.path))
    }

    @Test("Two databases can coexist in the same folder")
    func twoSideBySide() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spa-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        _ = try ReportDatabase(folderPath: tmpDir, name: ".report-http.db")
        _ = try ReportDatabase(folderPath: tmpDir, name: ".report-native.db")

        let httpURL = tmpDir.appendingPathComponent(".report-http.db")
        let nativeURL = tmpDir.appendingPathComponent(".report-native.db")
        #expect(FileManager.default.fileExists(atPath: httpURL.path))
        #expect(FileManager.default.fileExists(atPath: nativeURL.path))
    }

    @Test("PipelineCoordinator.process uses the databaseName parameter")
    func pipelineProcessHonorsDatabaseName() async throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("spa-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // PipelineCoordinator.process scans the folder and opens a report DB.
        // With no photos in the folder, scanning returns zero files and the
        // DB is opened but nothing is written. That still exercises the
        // databaseName parameter path end-to-end through PipelineCoordinator.
        let coordinator = PipelineCoordinator(inferenceClient: MockInferenceClient())
        await coordinator.process(
            folder: tmpDir,
            ratingConfig: RatingEngine.Config(sharpnessThreshold: 380, aestheticsThreshold: 4.8),
            exposureEnabled: false,
            exposureThreshold: 0.10,
            burstDetectionEnabled: false,
            databaseName: ".report-pipeline.db"
        )

        let customURL = tmpDir.appendingPathComponent(".report-pipeline.db")
        let defaultURL = tmpDir.appendingPathComponent(".report.db")
        #expect(FileManager.default.fileExists(atPath: customURL.path))
        #expect(!FileManager.default.fileExists(atPath: defaultURL.path))
    }
}
