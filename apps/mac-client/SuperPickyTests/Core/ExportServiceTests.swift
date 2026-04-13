import Testing
import Foundation
@testable import SuperPicky

@Suite struct ExportServiceTests {

    // MARK: - Helpers

    private func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ExportServiceTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func makePhoto(
        in dir: URL,
        filename: String = "IMG_0001.CR3",
        starRating: Int = 3,
        speciesCommonName: String? = "Robin",
        speciesScientificName: String? = nil,
        isFlying: Bool = false
    ) throws -> Photo {
        let filePath = dir.appendingPathComponent(filename)
        // Create a dummy source file
        try Data("fake raw data".utf8).write(to: filePath)

        var photo = Photo(
            filename: filename,
            filePath: filePath.path,
            folderPath: dir.path
        )
        photo.starRating = starRating
        photo.speciesCommonName = speciesCommonName
        photo.speciesScientificName = speciesScientificName
        photo.isFlying = isFlying
        return photo
    }

    // MARK: - Export copies files to destination

    @Test func exportCopiesFilesToDestination() async throws {
        let sourceDir = try makeTempDir()
        let destDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: destDir)
        }

        let photo = try makePhoto(in: sourceDir)
        let result = try await ExportService.export(
            photos: [photo],
            to: destDir,
            onProgress: { _, _ in }
        )

        #expect(result.exportedCount == 1)
        #expect(result.skippedCount == 0)
        #expect(result.failedCount == 0)

        let copiedFile = destDir.appendingPathComponent("IMG_0001.CR3")
        #expect(FileManager.default.fileExists(atPath: copiedFile.path))
    }

    // MARK: - Export writes XMP sidecars

    @Test func exportWritesXMPSidecars() async throws {
        let sourceDir = try makeTempDir()
        let destDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: destDir)
        }

        let photo = try makePhoto(in: sourceDir, speciesCommonName: "Bald Eagle")
        let _ = try await ExportService.export(
            photos: [photo],
            to: destDir,
            onProgress: { _, _ in }
        )

        // XMP should exist in source directory
        let sourceXMP = sourceDir.appendingPathComponent("IMG_0001.xmp")
        #expect(FileManager.default.fileExists(atPath: sourceXMP.path))

        // XMP should also exist in destination directory
        let destXMP = destDir.appendingPathComponent("IMG_0001.xmp")
        #expect(FileManager.default.fileExists(atPath: destXMP.path))

        // Verify content
        let content = try String(contentsOf: destXMP, encoding: .utf8)
        #expect(content.contains("Bald Eagle"))
    }

    // MARK: - Export skips existing files

    @Test func exportSkipsExistingFiles() async throws {
        let sourceDir = try makeTempDir()
        let destDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: destDir)
        }

        let photo = try makePhoto(in: sourceDir)

        // Pre-create the file in destination
        let existingFile = destDir.appendingPathComponent("IMG_0001.CR3")
        try Data("already here".utf8).write(to: existingFile)

        let result = try await ExportService.export(
            photos: [photo],
            to: destDir,
            onProgress: { _, _ in }
        )

        #expect(result.exportedCount == 0)
        #expect(result.skippedCount == 1)

        // Original content should be preserved (not overwritten)
        let content = try String(contentsOf: existingFile, encoding: .utf8)
        #expect(content == "already here")
    }

    // MARK: - Export empty list

    @Test func exportEmptyListReturnsZeros() async throws {
        let destDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: destDir) }

        let result = try await ExportService.export(
            photos: [],
            to: destDir,
            onProgress: { _, _ in }
        )

        #expect(result.exportedCount == 0)
        #expect(result.skippedCount == 0)
        #expect(result.failedCount == 0)
        #expect(result.errors.isEmpty)
    }

    // MARK: - Export reports correct counts

    @Test func exportReportsCorrectCounts() async throws {
        let sourceDir = try makeTempDir()
        let destDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: destDir)
        }

        let photo1 = try makePhoto(in: sourceDir, filename: "IMG_0001.CR3")
        let photo2 = try makePhoto(in: sourceDir, filename: "IMG_0002.CR3")
        let photo3 = try makePhoto(in: sourceDir, filename: "IMG_0003.CR3")

        let result = try await ExportService.export(
            photos: [photo1, photo2, photo3],
            to: destDir,
            onProgress: { _, _ in }
        )

        #expect(result.exportedCount == 3)
        #expect(result.skippedCount == 0)
        #expect(result.failedCount == 0)
    }

    // MARK: - Progress callback is called

    @Test func exportCallsProgressCallback() async throws {
        let sourceDir = try makeTempDir()
        let destDir = try makeTempDir()
        defer {
            try? FileManager.default.removeItem(at: sourceDir)
            try? FileManager.default.removeItem(at: destDir)
        }

        let photo1 = try makePhoto(in: sourceDir, filename: "IMG_0001.CR3")
        let photo2 = try makePhoto(in: sourceDir, filename: "IMG_0002.CR3")

        var progressCalls: [(Int, Int)] = []
        let _ = try await ExportService.export(
            photos: [photo1, photo2],
            to: destDir,
            onProgress: { current, total in
                progressCalls.append((current, total))
            }
        )

        #expect(progressCalls.count == 2)
        #expect(progressCalls[0] == (1, 2))
        #expect(progressCalls[1] == (2, 2))
    }
}
