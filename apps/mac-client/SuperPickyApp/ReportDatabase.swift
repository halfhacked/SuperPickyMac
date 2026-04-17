import Foundation
import GRDB

final class ReportDatabase: Sendable {
    private let dbQueue: DatabaseQueue

    init(folderPath: URL, name: String = ".report.db") throws {
        let dbPath = folderPath.appendingPathComponent(name).path
        dbQueue = try DatabaseQueue(path: dbPath)
        try migrate()
    }

    private func migrate() throws {
        var migrator = DatabaseMigrator()
        migrator.registerMigration("v1") { db in
            try db.create(table: "photos", ifNotExists: true) { t in
                t.column("id", .text).notNull().primaryKey()
                t.column("filename", .text).notNull()
                t.column("filePath", .text).notNull()
                t.column("folderPath", .text).notNull()
                t.column("dateCreated", .datetime).notNull()
                t.column("birdConfidence", .double)
                t.column("birdBbox", .blob)
                t.column("birdMask", .blob)
                t.column("aestheticsScore", .double)
                t.column("leftEyeX", .double)
                t.column("leftEyeY", .double)
                t.column("leftEyeVis", .double)
                t.column("rightEyeX", .double)
                t.column("rightEyeY", .double)
                t.column("rightEyeVis", .double)
                t.column("beakX", .double)
                t.column("beakY", .double)
                t.column("beakVis", .double)
                t.column("isFlying", .boolean).notNull().defaults(to: false)
                t.column("flightConfidence", .double)
                t.column("sharpnessScore", .double)
                t.column("exposureStatus", .text)
                t.column("focusPointStatus", .text)
                t.column("starRating", .integer).notNull().defaults(to: 0)
                t.column("isPick", .boolean).notNull().defaults(to: false)
                t.column("speciesScientificName", .text)
                t.column("speciesCommonName", .text)
                t.column("speciesConfidence", .double)
                t.column("burstGroupID", .text)
                t.column("isBurstBest", .boolean).notNull().defaults(to: false)
            }
            try db.create(indexOn: "photos", columns: ["folderPath"])
            try db.create(indexOn: "photos", columns: ["starRating"])
            try db.create(indexOn: "photos", columns: ["speciesScientificName"])
            try db.create(indexOn: "photos", columns: ["burstGroupID"])
        }
        migrator.registerMigration("v2_cn_pinyin") { db in
            try db.alter(table: "photos") { t in
                t.add(column: "speciesCnName", .text)
                t.add(column: "speciesPinyin", .text)
            }
        }
        migrator.registerMigration("v2") { db in
            try db.alter(table: "photos") { t in
                t.add(column: "isManualRating", .boolean).notNull().defaults(to: false)
            }
            try db.execute(sql: "UPDATE photos SET starRating = 0 WHERE starRating = -1")
        }
        migrator.registerMigration("v3_remove_dead_columns") { db in
            try db.execute(sql: "ALTER TABLE photos DROP COLUMN birdBbox")
            try db.execute(sql: "ALTER TABLE photos DROP COLUMN birdMask")
            try db.execute(sql: "ALTER TABLE photos DROP COLUMN focusPointStatus")
        }
        migrator.registerMigration("v4_eye_sharpness") { db in
            try db.alter(table: "photos") { t in
                t.add(column: "eyeSharpnessScore", .double)
            }
        }
        migrator.registerMigration("v5_parity_fields") { db in
            // JSON-encoded payloads for the parity harness. All three are
            // strictly additive — NULL on existing rows, populated on next
            // reprocess. No schema surface in the UI path.
            try db.alter(table: "photos") { t in
                // Full top-5 species from OSEA as JSON array of SpeciesMatch.
                t.add(column: "speciesTop5JSON", .text)
                // Full 10-bin AVA distribution from CFANet as JSON array.
                t.add(column: "aestheticsDistributionJSON", .text)
                // Normalized YOLO bbox [x1, y1, x2, y2] as JSON array.
                t.add(column: "birdBboxJSON", .text)
            }
        }
        migrator.registerMigration("v6_drop_eye_sharpness") { db in
            try db.execute(sql: "ALTER TABLE photos DROP COLUMN eyeSharpnessScore")
        }
        migrator.registerMigration("v7_reverse_geolocation") { db in
            // Reverse-geocoded placemark fields, populated by
            // PipelineCoordinator from CLGeocoder via ReverseGeocoder.
            try db.alter(table: "photos") { t in
                t.add(column: "locationCity", .text)
                t.add(column: "locationState", .text)
                t.add(column: "locationCountry", .text)
                t.add(column: "locationCountryCode", .text)
                t.add(column: "locationSublocation", .text)
            }
        }
        try migrator.migrate(dbQueue)
    }

    func save(_ photo: inout Photo) throws {
        try dbQueue.write { db in
            try photo.save(db)
        }
    }

    func fetchPhoto(id: UUID) throws -> Photo? {
        try dbQueue.read { db in
            try Photo.fetchOne(db, key: id)
        }
    }

    func fetchPhotos(starRating: Int) throws -> [Photo] {
        try dbQueue.read { db in
            try Photo.filter(Column("starRating") == starRating).fetchAll(db)
        }
    }

    func fetchByFilePath(_ filePath: String) throws -> Photo? {
        try dbQueue.read { db in
            try Photo.filter(Column("filePath") == filePath).fetchOne(db)
        }
    }

    /// One-shot set of every filePath already stored — used by the
    /// pipeline to skip already-processed photos without an N+1 query.
    func fetchAllFilePaths() throws -> Set<String> {
        try dbQueue.read { db in
            let paths = try String.fetchAll(db, sql: "SELECT filePath FROM photos")
            return Set(paths)
        }
    }

    func fetchAllPhotos() throws -> [Photo] {
        try dbQueue.read { db in
            try Photo.fetchAll(db)
        }
    }

    func ratingCounts() throws -> [Int: Int] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(db, sql: "SELECT starRating, COUNT(*) as cnt FROM photos GROUP BY starRating")
            var result: [Int: Int] = [:]
            for row in rows {
                result[row["starRating"]] = row["cnt"]
            }
            return result
        }
    }

    func delete(id: UUID) throws {
        try dbQueue.write { db in
            _ = try Photo.deleteOne(db, key: id)
        }
    }

    /// Delete all photos that were NOT manually rated (keep manual overrides).
    func deleteNonManualPhotos() throws {
        try dbQueue.write { db in
            try db.execute(sql: "DELETE FROM photos WHERE isManualRating = 0")
        }
    }
}
