import Foundation
import GRDB

struct PhotoMutationResult: Sendable {
    let previous: Photo
    let updated: Photo
}

/// A captured "desired" species assignment for one photo. Persistence overlays
/// this list onto a freshly-fetched database row so concurrent pipeline writes
/// to non-species fields are preserved.
struct SpeciesSnapshot: Sendable {
    let id: UUID
    let species: [SpeciesMatch]
}

final class ReportDatabase: Sendable {
    private let dbQueue: DatabaseQueue

    init(folderPath: URL, name: String = ".report.db") throws {
        let dbPath = folderPath.appendingPathComponent(name).path
        // The report DB is a derived cache — XMP sidecars hold the durable
        // copy — so trading a narrow power-loss window for cheaper per-
        // commit fsync (WAL + synchronous=NORMAL) is the right call.
        var config = Configuration()
        config.prepareDatabase { db in
            try db.execute(sql: "PRAGMA journal_mode = WAL")
            try db.execute(sql: "PRAGMA synchronous = NORMAL")
        }
        dbQueue = try DatabaseQueue(path: dbPath, configuration: config)
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
        migrator.registerMigration("v8_assigned_species") { db in
            // Multi-species tagging. Each photo now carries a JSON-encoded
            // list of SpeciesMatch objects; the scalar species* columns
            // continue to mirror the first entry for back-compat.
            try db.alter(table: "photos") { t in
                t.add(column: "assignedSpeciesJSON", .text)
            }
            // Backfill existing rows: emit a one-element list derived from
            // the legacy scalar columns so pre-v8 photos show a consistent
            // assigned list immediately (no reprocess required).
            let rows = try Row.fetchAll(db, sql: """
                SELECT id, speciesScientificName, speciesCommonName,
                       speciesCnName, speciesPinyin, speciesConfidence
                FROM photos
                WHERE speciesScientificName IS NOT NULL
            """)
            for row in rows {
                // Existing DBs store `id` as BLOB (GRDB's default UUID encoding)
                // even though the schema declared `.text`. Pass it through as a
                // raw DatabaseValue so we don't need to assume the storage type.
                let id: DatabaseValue = row["id"]
                let sci: String = row["speciesScientificName"]
                let match = SpeciesMatch(
                    scientificName: sci,
                    commonName: row["speciesCommonName"],
                    confidence: row["speciesConfidence"] ?? 0,
                    cnName: row["speciesCnName"],
                    pinyin: row["speciesPinyin"],
                    thresholdUsed: nil,
                    ebirdCode: nil
                )
                if let data = try? JSONEncoder().encode([match]),
                   let json = String(data: data, encoding: .utf8) {
                    try db.execute(
                        sql: "UPDATE photos SET assignedSpeciesJSON = ? WHERE id = ?",
                        arguments: [json, id]
                    )
                }
            }
        }
        migrator.registerMigration("v9_rejected_state") { db in
            let hasRejectedColumn = try Int.fetchOne(
                db,
                sql: """
                    SELECT COUNT(*)
                    FROM pragma_table_info('photos')
                    WHERE name = 'isRejected'
                    """
            ) == 1
            if !hasRejectedColumn {
                try db.alter(table: "photos") { t in
                    t.add(column: "isRejected", .boolean).notNull().defaults(to: false)
                }
            }
            // Legacy zero-star rows are intentionally left non-rejected because
            // the old schema cannot prove whether the user pressed 0 or X.
            try db.execute(sql: """
                CREATE INDEX IF NOT EXISTS index_photos_on_isRejected
                ON photos(isRejected)
            """)
        }
        try migrator.migrate(dbQueue)
    }

    func save(_ photo: inout Photo) throws {
        try dbQueue.write { db in
            try photo.save(db)
        }
    }

    func saveAll(_ photos: inout [Photo]) throws {
        try dbQueue.write { db in
            for index in photos.indices {
                try photos[index].save(db)
            }
        }
    }

    /// Fetch, mutate, and save a photo batch in one transaction. Keeping the
    /// read-modify-write cycle atomic prevents concurrent pipeline writes from
    /// interleaving between an edit's reads and saves.
    func mutatePhotos(
        ids: [UUID],
        _ mutate: @Sendable (inout [Photo]) -> Void
    ) throws -> [PhotoMutationResult] {
        try dbQueue.write { db in
            var previous: [Photo] = []
            previous.reserveCapacity(ids.count)
            for id in ids {
                if let photo = try Photo.fetchOne(db, key: id) {
                    previous.append(photo)
                }
            }

            var updated = previous
            mutate(&updated)
            precondition(
                updated.map(\.id) == previous.map(\.id),
                "Photo batch mutations must preserve identity and order"
            )
            for index in updated.indices {
                try updated[index].save(db)
            }

            return zip(previous, updated).map {
                PhotoMutationResult(previous: $0.0, updated: $0.1)
            }
        }
    }

    /// Overlay captured species assignments onto freshly-fetched rows.
    ///
    /// Each snapshot is applied to the *current* database row for that photo so
    /// concurrent pipeline writes to non-species fields survive. Rows whose
    /// assigned species already equal the desired list are skipped (no write).
    /// Returns the rows that were actually updated so the caller can queue XMP
    /// writes for them — the caller must NOT publish these back into the UI,
    /// which already holds the optimistic state.
    func overlaySpecies(_ snapshots: [SpeciesSnapshot]) throws -> [Photo] {
        try dbQueue.write { db in
            var written: [Photo] = []
            written.reserveCapacity(snapshots.count)
            for snapshot in snapshots {
                guard var photo = try Photo.fetchOne(db, key: snapshot.id) else { continue }
                if photo.assignedSpecies == snapshot.species { continue }
                photo.assignedSpecies = snapshot.species
                try photo.save(db)
                written.append(photo)
            }
            return written
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

    /// Capture timestamp keyed by file path for resume ordering. Existing
    /// photos can participate in the timestamp sequence without re-opening
    /// every RAW file during the metadata pre-pass.
    func fetchAllFileDates() throws -> [String: Date] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db, sql: "SELECT filePath, dateCreated FROM photos"
            )
            var dates: [String: Date] = [:]
            dates.reserveCapacity(rows.count)
            for row in rows {
                dates[row["filePath"]] = row["dateCreated"]
            }
            return dates
        }
    }

    func fetchAllPhotos() throws -> [Photo] {
        try dbQueue.read { db in
            // Filename tiebreaker — burst shots can share an EXIF
            // DateTimeOriginal down to the SubSecTimeOriginal precision, and
            // some camera bodies don't write SubSec at all. Without a stable
            // tiebreaker the strip order would be arbitrary on those rows.
            try Photo.order(Column("dateCreated"), Column("filename")).fetchAll(db)
        }
    }

    func ratingCounts() throws -> [Int: Int] {
        try dbQueue.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT starRating, COUNT(*) as cnt FROM photos GROUP BY starRating"
            )
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

    /// Delete photos with no manual culling decision so the pipeline can
    /// reprocess them. Manual ratings and explicit rejections are preserved.
    func deleteNonManualPhotos() throws {
        try dbQueue.write { db in
            try db.execute(
                sql: "DELETE FROM photos WHERE isManualRating = 0 AND isRejected = 0"
            )
        }
    }
}
