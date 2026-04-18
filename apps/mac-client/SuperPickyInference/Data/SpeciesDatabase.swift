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
    public let ebirdCode: String?
}

public final class SpeciesDatabase: Sendable {

    private let byClassID: [Int: SpeciesEntry]
    /// Flat array for linear-scan autocomplete. Holds the same values as
    /// `byClassID` but in a form that's cheap to iterate without materializing
    /// the dictionary's values on each search call.
    private let all: [SpeciesEntry]
    private let logger = Logger(subsystem: "com.superpicky.mac", category: "SpeciesDB")

    public init(url: URL, ebirdByClassID: [Int: String] = [:]) throws {
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
                                          pinyin: pinyin,
                                          ebirdCode: ebirdByClassID[classID])
        }
        self.byClassID = dict
        self.all = Array(dict.values)
    }

    public func lookup(classID: Int) -> SpeciesEntry? {
        byClassID[classID]
    }

    /// Substring autocomplete across english / scientific / chinese / pinyin.
    /// Ranks prefix matches ahead of substring matches, then alphabetical by
    /// english name. Linear scan over ~11k entries is fine at typing speeds.
    public func search(query: String, limit: Int = 20) -> [SpeciesEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }

        struct Scored {
            let entry: SpeciesEntry
            let score: Int
        }

        var scored: [Scored] = []
        scored.reserveCapacity(64)
        for entry in all {
            let eng = entry.englishName.lowercased()
            let sci = entry.scientificName.lowercased()
            let cn  = entry.chineseName.lowercased()
            let py  = entry.pinyin?.lowercased() ?? ""

            var score = 0
            if eng.hasPrefix(trimmed) || sci.hasPrefix(trimmed)
                || cn.hasPrefix(trimmed) || (!py.isEmpty && py.hasPrefix(trimmed)) {
                score = 3
            } else if eng.contains(trimmed) || sci.contains(trimmed)
                || cn.contains(trimmed) || (!py.isEmpty && py.contains(trimmed)) {
                score = 1
            }
            if score > 0 {
                scored.append(Scored(entry: entry, score: score))
            }
        }

        scored.sort { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.entry.englishName.localizedCaseInsensitiveCompare(b.entry.englishName) == .orderedAscending
        }
        return scored.prefix(limit).map { $0.entry }
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
