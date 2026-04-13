import Testing
import Foundation
@testable import SuperPicky

@Suite struct FileOrganizerTests {
    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func organizesIntoStarFolders() throws {
        let tempDir = try makeTempDir()
        let file3star = tempDir.appendingPathComponent("excellent.jpg")
        let file1star = tempDir.appendingPathComponent("average.jpg")
        FileManager.default.createFile(atPath: file3star.path, contents: Data("test".utf8))
        FileManager.default.createFile(atPath: file1star.path, contents: Data("test".utf8))

        let organizer = FileOrganizer()
        try organizer.organize(file: file3star, starRating: 3, inFolder: tempDir)
        try organizer.organize(file: file1star, starRating: 1, inFolder: tempDir)

        #expect(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("3star_excellent/excellent.jpg").path))
        #expect(FileManager.default.fileExists(atPath: tempDir.appendingPathComponent("1star_average/average.jpg").path))
    }

    @Test func folderNames() {
        let organizer = FileOrganizer()
        #expect(organizer.folderName(for: 0) == "0star_reject")
        #expect(organizer.folderName(for: 1) == "1star_average")
        #expect(organizer.folderName(for: 2) == "2star_good")
        #expect(organizer.folderName(for: 3) == "3star_excellent")
    }
}
