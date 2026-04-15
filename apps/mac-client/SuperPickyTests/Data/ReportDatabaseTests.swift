import Testing
import Foundation
import GRDB
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

    @Test func v2MigrationAddsIsManualRatingAndRemapsMinus1() throws {
        let tempDir = try makeTempDir()
        let dbPath = tempDir.appendingPathComponent(".report.db").path

        // Create a v1-only database with a -1 rating row
        let queue = try DatabaseQueue(path: dbPath)
        try queue.write { db in
            try db.execute(sql: """
                CREATE TABLE photos (
                    id TEXT NOT NULL PRIMARY KEY,
                    filename TEXT NOT NULL,
                    filePath TEXT NOT NULL,
                    folderPath TEXT NOT NULL,
                    dateCreated DATETIME NOT NULL,
                    birdConfidence DOUBLE,
                    birdBbox BLOB,
                    birdMask BLOB,
                    aestheticsScore DOUBLE,
                    leftEyeX DOUBLE, leftEyeY DOUBLE, leftEyeVis DOUBLE,
                    rightEyeX DOUBLE, rightEyeY DOUBLE, rightEyeVis DOUBLE,
                    beakX DOUBLE, beakY DOUBLE, beakVis DOUBLE,
                    isFlying BOOLEAN NOT NULL DEFAULT 0,
                    flightConfidence DOUBLE,
                    sharpnessScore DOUBLE,
                    exposureStatus TEXT,
                    focusPointStatus TEXT,
                    starRating INTEGER NOT NULL DEFAULT 0,
                    isPick BOOLEAN NOT NULL DEFAULT 0,
                    speciesScientificName TEXT,
                    speciesCommonName TEXT,
                    speciesConfidence DOUBLE,
                    burstGroupID TEXT,
                    isBurstBest BOOLEAN NOT NULL DEFAULT 0
                )
            """)
            // Insert grdb_migrations so v1 is already "applied"
            try db.execute(sql: "CREATE TABLE grdb_migrations (identifier TEXT NOT NULL PRIMARY KEY)")
            try db.execute(sql: "INSERT INTO grdb_migrations (identifier) VALUES ('v1')")
            // Insert a photo with starRating = -1 (legacy)
            let id = UUID().uuidString
            try db.execute(sql: """
                INSERT INTO photos (id, filename, filePath, folderPath, dateCreated, isFlying, starRating, isPick, isBurstBest)
                VALUES (?, 'legacy.CR3', '/tmp/legacy.CR3', ?, datetime('now'), 0, -1, 0, 0)
            """, arguments: [id, tempDir.path])
        }

        // Now open via ReportDatabase which should run v2 migration
        let reportDb = try ReportDatabase(folderPath: tempDir)
        let allPhotos = try reportDb.fetchAllPhotos()
        #expect(allPhotos.count == 1)
        // -1 should be remapped to 0
        #expect(allPhotos[0].starRating == 0)
        // isManualRating column should exist and default to false
        #expect(allPhotos[0].isManualRating == false)
    }

    @Test func isManualRatingDefaultsFalseForNewPhotos() throws {
        let tempDir = try makeTempDir()
        let db = try ReportDatabase(folderPath: tempDir)
        var photo = Photo(filename: "IMG_NEW.CR3", filePath: "/tmp/IMG_NEW.CR3", folderPath: tempDir.path)
        try db.save(&photo)
        let fetched = try db.fetchPhoto(id: photo.id)
        #expect(fetched != nil)
        #expect(fetched?.isManualRating == false)
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

    @Test func deletePhoto_removesFromDatabase() throws {
        let dir = try makeTempDir()
        var db = try ReportDatabase(folderPath: dir)
        var photo = Photo(filename: "test.jpg", filePath: "/tmp/test.jpg", folderPath: dir.path)
        try db.save(&photo)
        try db.delete(id: photo.id)
        let fetched = try db.fetchPhoto(id: photo.id)
        #expect(fetched == nil)
    }

    @Test func deleteNonManualPhotos_preservesManualRatings() throws {
        let dir = try makeTempDir()
        var db = try ReportDatabase(folderPath: dir)

        var autoPhoto = Photo(filename: "auto.jpg", filePath: "/tmp/auto.jpg", folderPath: dir.path)
        autoPhoto.isManualRating = false
        try db.save(&autoPhoto)

        var manualPhoto = Photo(filename: "manual.jpg", filePath: "/tmp/manual.jpg", folderPath: dir.path)
        manualPhoto.isManualRating = true
        manualPhoto.starRating = 4
        try db.save(&manualPhoto)

        try db.deleteNonManualPhotos()

        let remaining = try db.fetchAllPhotos()
        #expect(remaining.count == 1)
        #expect(remaining[0].filename == "manual.jpg")
    }
}
