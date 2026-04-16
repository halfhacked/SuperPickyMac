// SpeciesFilter.swift
//
// Port of ~/projects/SuperPicky/birdid/avonet_filter.py.
// Given a GPS coordinate, returns the set of OSEA class IDs that
// are plausible for that location, for masking OSEA logits before
// softmax so we don't pick global lookalikes in the wrong hemisphere.
//
// Fallback cascade (matches Python identify_bird):
//   1. Avonet distribution grid  (1×1° cells in avonet.db)
//   2. eBird per-country species list (species_list_{code}.json)
//   3. Global — caller treats nil as "no mask, pick from all classes"
//
// Data sources:
//   - avonet.db: downloaded on first launch via ModelManager, lives
//     at ~/Library/.../ModelCache/avonet.db. Schema:
//       places(worldid, south, north, west, east)
//       distributions(id, species, worldid)
//       sp_cls_map(species, cls)
//   - eBird JSONs: bundled in the SuperPickyInference framework at
//     Resources/ebird/{species_list_*.json, ebird_classid_mapping.json}

import Foundation
import SQLite3
import os

public final class SpeciesFilter: @unchecked Sendable {

    private let ebirdBundle: Bundle
    /// Inverted map: eBird code ("mallar3") → OSEA class id (integer).
    private let classIDByEbirdCode: [String: Int]
    private let logger = Logger(subsystem: "com.superpicky.mac", category: "SpeciesFilter")

    /// Long-lived SQLite handle. nil if the DB file wasn't present at init
    /// (offline first-launch). SQLITE_OPEN_FULLMUTEX makes the connection
    /// safe to share across threads — no extra locking needed.
    private let avonetDB: OpaquePointer?

    /// Cache of parsed eBird regional species sets. Empty set = cached miss.
    private let ebirdCacheLock = NSLock()
    private var ebirdCache: [String: Set<Int>] = [:]

    /// - Parameters:
    ///   - avonetPath: Path to the Avonet SQLite DB (downloaded via
    ///     ModelManager). If the file doesn't exist, Avonet queries
    ///     return nil and we fall straight through to the eBird JSONs.
    ///   - ebirdBundle: Bundle containing the bundled eBird JSON files
    ///     under Resources/ebird/. Defaults to the SuperPickyInference
    ///     framework bundle.
    public init(avonetPath: URL, ebirdBundle: Bundle = .inferenceModule) throws {
        self.ebirdBundle = ebirdBundle
        self.classIDByEbirdCode = try Self.loadClassIDMapping(from: ebirdBundle)

        var db: OpaquePointer?
        if FileManager.default.fileExists(atPath: avonetPath.path) {
            let rc = sqlite3_open_v2(avonetPath.path, &db,
                                     SQLITE_OPEN_READONLY | SQLITE_OPEN_FULLMUTEX, nil)
            if rc != SQLITE_OK {
                sqlite3_close(db)
                db = nil
            }
        }
        self.avonetDB = db
    }

    deinit {
        if let avonetDB { sqlite3_close(avonetDB) }
    }

    // MARK: - Public API

    /// Returns the set of allowed OSEA class IDs for the given GPS, or
    /// `nil` when no filter applies (caller should NOT mask logits).
    public func allowedClassIDs(lat: Double, lon: Double) -> Set<Int>? {
        if let ids = queryAvonet(lat: lat, lon: lon), !ids.isEmpty {
            return ids
        }
        if let country = RegionBounds.smallestContaining(lat: lat, lon: lon),
           let ids = loadEbirdSpecies(regionCode: country), !ids.isEmpty {
            return ids
        }
        return nil
    }

    // MARK: - Avonet SQLite query

    private func queryAvonet(lat: Double, lon: Double) -> Set<Int>? {
        guard let db = avonetDB else { return nil }

        // Same query as AvonetSpeciesFilter.get_species_by_gps.
        let sql = """
            SELECT DISTINCT sm.cls
            FROM distributions d
            JOIN places p ON d.worldid = p.worldid
            JOIN sp_cls_map sm ON d.species = sm.species
            WHERE ? BETWEEN p.south AND p.north
              AND ? BETWEEN p.west AND p.east
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK, let stmt else {
            return nil
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, lat)
        sqlite3_bind_double(stmt, 2, lon)

        var ids = Set<Int>()
        while sqlite3_step(stmt) == SQLITE_ROW {
            ids.insert(Int(sqlite3_column_int(stmt, 0)))
        }
        return ids.isEmpty ? nil : ids
    }

    // MARK: - eBird JSON fallback

    private func loadEbirdSpecies(regionCode: String) -> Set<Int>? {
        ebirdCacheLock.lock()
        if let cached = ebirdCache[regionCode] {
            ebirdCacheLock.unlock()
            return cached.isEmpty ? nil : cached
        }
        ebirdCacheLock.unlock()

        let parsed = parseEbirdSpeciesUncached(regionCode: regionCode) ?? []
        ebirdCacheLock.lock()
        ebirdCache[regionCode] = parsed
        ebirdCacheLock.unlock()
        return parsed.isEmpty ? nil : parsed
    }

    private func parseEbirdSpeciesUncached(regionCode: String) -> Set<Int>? {
        guard let url = ebirdBundle.url(forResource: "species_list_\(regionCode)",
                                         withExtension: "json",
                                         subdirectory: "ebird") else {
            // Try without subdirectory (SPM sometimes flattens).
            guard let flat = ebirdBundle.url(forResource: "species_list_\(regionCode)",
                                              withExtension: "json") else {
                logger.info("No eBird list for region \(regionCode, privacy: .public)")
                return nil
            }
            return parseEbirdJSON(at: flat)
        }
        return parseEbirdJSON(at: url)
    }

    private func parseEbirdJSON(at url: URL) -> Set<Int>? {
        // File format matches Python's save path in avonet_filter.py:
        //   { "country_code": "US", "species": ["ostric2", "emu1", ...] }
        // Older snapshots may have dumped a bare array — decode both.
        struct EbirdCountryList: Decodable {
            let species: [String]
        }
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        let codes: [String]
        if let wrapped = try? JSONDecoder().decode(EbirdCountryList.self, from: data) {
            codes = wrapped.species
        } else if let bare = try? JSONDecoder().decode([String].self, from: data) {
            codes = bare
        } else {
            logger.error("Unparseable eBird JSON at \(url.lastPathComponent, privacy: .public)")
            return nil
        }
        var ids = Set<Int>()
        for code in codes {
            if let id = classIDByEbirdCode[code] { ids.insert(id) }
        }
        return ids.isEmpty ? nil : ids
    }

    // MARK: - Class ID mapping loader

    private static func loadClassIDMapping(from bundle: Bundle) throws -> [String: Int] {
        let url = bundle.url(forResource: "ebird_classid_mapping",
                             withExtension: "json",
                             subdirectory: "ebird")
            ?? bundle.url(forResource: "ebird_classid_mapping", withExtension: "json")
        guard let url else {
            throw SpeciesFilterError.missingMappingJSON
        }
        let data = try Data(contentsOf: url)
        // Python file is {"0": "ostric2", "1": "ostric3", ...} — invert.
        let raw = try JSONDecoder().decode([String: String].self, from: data)
        var inverted: [String: Int] = [:]
        inverted.reserveCapacity(raw.count)
        for (classIDString, ebirdCode) in raw {
            if let classID = Int(classIDString) {
                inverted[ebirdCode] = classID
            }
        }
        return inverted
    }
}

public enum SpeciesFilterError: Error {
    case missingMappingJSON
}
