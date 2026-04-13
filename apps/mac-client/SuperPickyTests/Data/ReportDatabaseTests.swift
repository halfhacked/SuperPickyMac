import Testing
import Foundation
@testable import SuperPicky

@Suite struct ReportDatabaseTests {
    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    @Test func createAndFetchPhoto() throws {
        let tempDir = try makeTempDir()
        let db = try ReportDatabase(folderPath: tempDir)
        var photo = Photo(filename: "IMG_001.CR3", filePath: tempDir.appendingPathComponent("IMG_001.CR3").path, folderPath: tempDir.path)
        photo.starRating = 3
        photo.aestheticsScore = 6.5
        try db.save(&photo)

        let fetched = try db.fetchPhoto(id: photo.id)
        #expect(fetched != nil)
        #expect(fetched?.starRating == 3)
        #expect(fetched?.aestheticsScore == 6.5)
    }

    @Test func fetchByRating() throws {
        let tempDir = try makeTempDir()
        let db = try ReportDatabase(folderPath: tempDir)
        for i in 0..<10 {
            var photo = Photo(filename: "IMG_\(i).CR3", filePath: "/tmp/IMG_\(i).CR3", folderPath: tempDir.path)
            photo.starRating = i % 4
            try db.save(&photo)
        }

        let threeStars = try db.fetchPhotos(starRating: 3)
        #expect(threeStars.count == 2)
    }

    @Test func countByRating() throws {
        let tempDir = try makeTempDir()
        let db = try ReportDatabase(folderPath: tempDir)
        for i in 0..<6 {
            var photo = Photo(filename: "IMG_\(i).CR3", filePath: "/tmp/IMG_\(i).CR3", folderPath: tempDir.path)
            photo.starRating = i < 3 ? 3 : 1
            try db.save(&photo)
        }

        let counts = try db.ratingCounts()
        #expect(counts[3] == 3)
        #expect(counts[1] == 3)
    }

    @Test func deletePhoto() throws {
        let tempDir = try makeTempDir()
        let db = try ReportDatabase(folderPath: tempDir)
        var photo = Photo(filename: "IMG_DEL.CR3", filePath: "/tmp/IMG_DEL.CR3", folderPath: tempDir.path)
        try db.save(&photo)
        try db.delete(id: photo.id)
        let fetched = try db.fetchPhoto(id: photo.id)
        #expect(fetched == nil)
    }
}
