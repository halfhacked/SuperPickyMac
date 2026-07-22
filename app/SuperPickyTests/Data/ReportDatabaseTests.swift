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
        photo.pickStatus = .rejected
        photo.aestheticsScore = 6.5
        try db.save(&photo)

        let fetched = try db.fetchPhoto(id: photo.id)
        #expect(fetched != nil)
        #expect(fetched?.starRating == 3)
        #expect(fetched?.pickStatus == .rejected)
        #expect(fetched?.aestheticsScore == 6.5)
    }

    @Test func fetchAllFileDatesReturnsPersistedCaptureDates() throws {
        let tempDir = try makeTempDir()
        let db = try ReportDatabase(folderPath: tempDir)
        let date = Date(timeIntervalSince1970: 1_700_000_000.125)
        var photo = Photo(
            filename: "dated.jpg",
            filePath: "/tmp/dated.jpg",
            folderPath: tempDir.path,
            dateCreated: date
        )
        try db.save(&photo)

        let dates = try db.fetchAllFileDates()
        let stored = try #require(dates[photo.filePath])
        #expect(
            abs(stored.timeIntervalSince1970 - date.timeIntervalSince1970) < 0.001
        )
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

    @Test func rejectedPhotosRemainInZeroStarQueries() throws {
        let tempDir = try makeTempDir()
        let db = try ReportDatabase(folderPath: tempDir)

        var zeroStar = Photo(
            filename: "zero.CR3",
            filePath: "/tmp/zero.CR3",
            folderPath: tempDir.path
        )
        try db.save(&zeroStar)

        var rejected = Photo(
            filename: "rejected.CR3",
            filePath: "/tmp/rejected.CR3",
            folderPath: tempDir.path
        )
        rejected.pickStatus = .rejected
        try db.save(&rejected)

        let zeroStarPhotos = try db.fetchPhotos(starRating: 0)
        #expect(Set(zeroStarPhotos.map(\.id)) == [zeroStar.id, rejected.id])
        #expect(try db.ratingCounts()[0] == 2)
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
                    pickStatus INTEGER NOT NULL DEFAULT 0,
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
                INSERT INTO photos (id, filename, filePath, folderPath, dateCreated, isFlying, starRating, pickStatus, isBurstBest)
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
        #expect(allPhotos[0].pickStatus == .unflagged)
    }

    @Test func isManualRatingDefaultsFalseForNewPhotos() throws {
        let tempDir = try makeTempDir()
        let db = try ReportDatabase(folderPath: tempDir)
        var photo = Photo(filename: "IMG_NEW.CR3", filePath: "/tmp/IMG_NEW.CR3", folderPath: tempDir.path)
        try db.save(&photo)
        let fetched = try db.fetchPhoto(id: photo.id)
        #expect(fetched != nil)
        #expect(fetched?.isManualRating == false)
        #expect(fetched?.pickStatus == .unflagged)
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
        let db = try ReportDatabase(folderPath: dir)
        var photo = Photo(filename: "test.jpg", filePath: "/tmp/test.jpg", folderPath: dir.path)
        try db.save(&photo)
        try db.delete(id: photo.id)
        let fetched = try db.fetchPhoto(id: photo.id)
        #expect(fetched == nil)
    }

    @Test func v8MigrationBackfillsAssignedSpeciesFromScalarColumns() throws {
        let tempDir = try makeTempDir()
        // Fresh DB via ReportDatabase — already at v8.
        let db = try ReportDatabase(folderPath: tempDir)

        // Insert a photo using ONLY the legacy scalar columns (simulating a
        // row written before the assignedSpecies accessor existed). Then
        // verify the accessor falls back to synthesizing a one-element
        // list so existing tests and persisted data keep working.
        var legacy = Photo(
            filename: "legacy.CR3",
            filePath: tempDir.appendingPathComponent("legacy.CR3").path,
            folderPath: tempDir.path
        )
        legacy.speciesScientificName = "Falco peregrinus"
        legacy.speciesCommonName = "Peregrine Falcon"
        legacy.speciesConfidence = 0.88
        try db.save(&legacy)

        // Clear assignedSpeciesJSON to mimic a pre-migration row that the
        // backfill wouldn't have seen (or any row where it's still nil),
        // then re-fetch to confirm the accessor fallback.
        let fetched = try db.fetchPhoto(id: legacy.id)
        var row = try #require(fetched)
        row.assignedSpeciesJSON = nil
        try db.save(&row)

        let reread = try db.fetchPhoto(id: legacy.id)
        let refetched = try #require(reread)
        #expect(refetched.assignedSpecies.count == 1)
        #expect(refetched.assignedSpecies.first?.scientificName == "Falco peregrinus")
        #expect(refetched.assignedSpecies.first?.commonName == "Peregrine Falcon")
    }

    @Test func deleteNonManualPhotosPreservesManualRatingsAndFlags() throws {
        let dir = try makeTempDir()
        let db = try ReportDatabase(folderPath: dir)

        var autoPhoto = Photo(filename: "auto.jpg", filePath: "/tmp/auto.jpg", folderPath: dir.path)
        autoPhoto.isManualRating = false
        try db.save(&autoPhoto)

        var manualPhoto = Photo(filename: "manual.jpg", filePath: "/tmp/manual.jpg", folderPath: dir.path)
        manualPhoto.isManualRating = true
        manualPhoto.starRating = 4
        try db.save(&manualPhoto)

        var rejectedPhoto = Photo(
            filename: "rejected.jpg",
            filePath: "/tmp/rejected.jpg",
            folderPath: dir.path
        )
        rejectedPhoto.pickStatus = .rejected
        try db.save(&rejectedPhoto)

        var pickedPhoto = Photo(
            filename: "picked.jpg",
            filePath: "/tmp/picked.jpg",
            folderPath: dir.path
        )
        pickedPhoto.pickStatus = .picked
        try db.save(&pickedPhoto)

        try db.deleteNonManualPhotos()

        let remaining = try db.fetchAllPhotos()
        #expect(Set(remaining.map(\.filename)) == ["manual.jpg", "picked.jpg", "rejected.jpg"])
    }
}
