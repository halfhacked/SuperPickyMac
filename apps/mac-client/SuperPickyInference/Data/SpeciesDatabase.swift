// SpeciesDatabase.swift
//
// In-memory species lookup loaded from the bundled bird_reference.sqlite.
//
// Loaded once at init time (~2 ms); all lookups are O(1) dictionary access.
// Thread-safe: the dictionary is immutable after init.

import Foundation
import SQLite3
import os

public struct SpeciesEntry: Sendable {
    public let classID: Int
    public let scientificName: String
    public let englishName: String
    public let chineseName: String
    public let pinyin: String?
}

public final class SpeciesDatabase: Sendable {

    private let byClassID: [Int: SpeciesEntry]
    private let logger = Logger(subsystem: "com.superpicky.mac", category: "SpeciesDB")

    public init(url: URL) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            throw SpeciesDatabaseError.openFailed(url.path)
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT model_class_id, scientific_name, english_name, chinese_simplified, pinyin
            FROM BirdCountInfo
            WHERE model_class_id IS NOT NULL
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            throw SpeciesDatabaseError.queryFailed
        }
        defer { sqlite3_finalize(stmt) }

        var dict = [Int: SpeciesEntry](minimumCapacity: 11000)
        while sqlite3_step(stmt) == SQLITE_ROW {
            let classID = Int(sqlite3_column_int(stmt, 0))
            let scientific = String(cString: sqlite3_column_text(stmt, 1))
            let english    = String(cString: sqlite3_column_text(stmt, 2))
            let chinese    = String(cString: sqlite3_column_text(stmt, 3))
            let pinyin: String? = sqlite3_column_type(stmt, 4) == SQLITE_NULL
                ? nil
                : String(cString: sqlite3_column_text(stmt, 4))
            dict[classID] = SpeciesEntry(classID: classID,
                                          scientificName: scientific,
                                          englishName: english,
                                          chineseName: chinese,
                                          pinyin: pinyin)
        }
        self.byClassID = dict
    }

    public func lookup(classID: Int) -> SpeciesEntry? {
        byClassID[classID]
    }

    /// Locate the bundled `bird_reference.sqlite` inside the SuperPickyInference
    /// resource bundle. For SPM builds that's `Bundle.module`; for xcodebuild
    /// framework builds it's the framework bundle located via a type anchor.
    public static func bundledURL() -> URL? {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: SpeciesDatabaseBundleAnchor.self)
        #endif
        return bundle.url(forResource: "bird_reference", withExtension: "sqlite")
    }
}

/// Anchor class used by `Bundle(for:)` to locate the framework's resource bundle
/// when built via xcodebuild. SPM builds use `Bundle.module` instead.
private final class SpeciesDatabaseBundleAnchor {}

public enum SpeciesDatabaseError: Error {
    case openFailed(String)
    case queryFailed
}
