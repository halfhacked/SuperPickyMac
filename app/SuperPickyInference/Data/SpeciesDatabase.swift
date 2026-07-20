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
    public let pinyinInitials: String?
    public let ebirdCode: String?
}

public final class SpeciesDatabase: Sendable {

    private struct SearchRecord: Sendable {
        let entry: SpeciesEntry
        let english: String
        let scientific: String
        let chinese: String
        let pinyin: String
        let pinyinInitials: String
    }

    private let byClassID: [Int: SpeciesEntry]
    /// Pre-normalized and alphabetized once at load time. Search can then scan
    /// without allocating five lowercase strings per species per keystroke or
    /// sorting thousands of broad-query matches.
    private let searchRecords: [SearchRecord]
    private let logger = Logger(subsystem: "com.halfhacked.superpicky", category: "SpeciesDB")

    public init(url: URL, ebirdByClassID: [Int: String] = [:]) throws {
        var db: OpaquePointer?
        guard sqlite3_open_v2(url.path, &db,
                              SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil) == SQLITE_OK,
              let db else {
            throw SpeciesDatabaseError.openFailed(url.path)
        }
        defer { sqlite3_close(db) }

        let sql = """
            SELECT model_class_id, scientific_name, english_name, chinese_simplified,
                   pinyin, pinyin_initials
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
            let pinyinInitials: String? = sqlite3_column_type(stmt, 5) == SQLITE_NULL
                ? nil
                : String(cString: sqlite3_column_text(stmt, 5))
            dict[classID] = SpeciesEntry(classID: classID,
                                          scientificName: scientific,
                                          englishName: english,
                                          chineseName: chinese,
                                          pinyin: pinyin,
                                          pinyinInitials: pinyinInitials,
                                          ebirdCode: ebirdByClassID[classID])
        }
        self.byClassID = dict
        self.searchRecords = dict.values
            .sorted {
                $0.englishName.localizedCaseInsensitiveCompare($1.englishName) == .orderedAscending
            }
            .map {
                SearchRecord(
                    entry: $0,
                    english: $0.englishName.lowercased(),
                    scientific: $0.scientificName.lowercased(),
                    chinese: $0.chineseName.lowercased(),
                    pinyin: $0.pinyin?.lowercased() ?? "",
                    pinyinInitials: $0.pinyinInitials?.lowercased() ?? ""
                )
            }
    }

    public func lookup(classID: Int) -> SpeciesEntry? {
        byClassID[classID]
    }

    /// Substring autocomplete across english / scientific / chinese / pinyin,
    /// plus prefix match on pinyin initials (e.g. "bthd" -> 白头海雕).
    /// Ranks prefix matches ahead of substring matches, then alphabetical by
    /// english name. The scan uses pre-normalized records and caps each ranked
    /// bucket at `limit`, avoiding per-keystroke lowercase and sort work.
    ///
    /// Initials are matched by prefix only (not substring): initials strings
    /// are short and noisy — a 2-letter substring like "sh" would otherwise
    /// match hundreds of species. Queries of 2+ ASCII letters are eligible
    /// for initials matching; single-letter queries are too broad.
    public func search(query: String, limit: Int = 20) -> [SpeciesEntry] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return [] }

        let initialsEligible = trimmed.count >= 2
            && trimmed.allSatisfy { $0.isASCII && $0.isLetter }

        var prefixMatches: [SpeciesEntry] = []
        var initialsMatches: [SpeciesEntry] = []
        var substringMatches: [SpeciesEntry] = []
        prefixMatches.reserveCapacity(limit)
        initialsMatches.reserveCapacity(limit)
        substringMatches.reserveCapacity(limit)

        for record in searchRecords {
            if record.english.hasPrefix(trimmed) || record.scientific.hasPrefix(trimmed)
                || record.chinese.hasPrefix(trimmed)
                || (!record.pinyin.isEmpty && record.pinyin.hasPrefix(trimmed)) {
                if prefixMatches.count < limit {
                    prefixMatches.append(record.entry)
                }
                if prefixMatches.count == limit { break }
            } else if initialsEligible && !record.pinyinInitials.isEmpty
                        && record.pinyinInitials.hasPrefix(trimmed) {
                if initialsMatches.count < limit {
                    initialsMatches.append(record.entry)
                }
            } else if record.english.contains(trimmed) || record.scientific.contains(trimmed)
                        || record.chinese.contains(trimmed)
                        || (!record.pinyin.isEmpty && record.pinyin.contains(trimmed)) {
                if substringMatches.count < limit {
                    substringMatches.append(record.entry)
                }
            }
        }

        var results: [SpeciesEntry] = []
        results.reserveCapacity(limit)
        for bucket in [prefixMatches, initialsMatches, substringMatches] {
            results.append(contentsOf: bucket.prefix(limit - results.count))
            if results.count == limit { break }
        }
        return results
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
