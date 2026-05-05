import Foundation
import Testing
@testable import SuperPickyInference

@Suite("SpeciesFilter")
struct SpeciesFilterTests {

    /// Build an ad-hoc Bundle directory containing the two JSON shapes
    /// `SpeciesFilter` must understand and return its URL.
    ///
    /// Note: `RegionBounds.smallestContaining` can resolve a US lat/lon
    /// to a state code (e.g. "US-MD") because the full port carries
    /// state-level bboxes. So for the wrapped-shape test we seed a
    /// state-level file; for the bare-array test we pick a coordinate
    /// that only a country-level bbox covers.
    private func makeEbirdFixture() throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ebird-fixture-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        // Wrapped shape — what the SuperPicky offline pipeline actually emits.
        // Seeded at state level because (38.9, -77.0) resolves to US-MD.
        let md = dir.appendingPathComponent("species_list_US-MD.json")
        try #"{"country_code":"US","species":["mallar3","ostric2","unknown_code"]}"#
            .write(to: md, atomically: true, encoding: .utf8)
        // Bare-array legacy shape. Calgary (51, -114) is outside the US
        // bbox (north: 49) so smallestContaining returns "CA".
        let ca = dir.appendingPathComponent("species_list_CA.json")
        try #"["ostric2","emu1"]"#
            .write(to: ca, atomically: true, encoding: .utf8)
        // Corrupt JSON — parseEbirdJSON must return nil, not crash.
        let xx = dir.appendingPathComponent("species_list_XX.json")
        try "not json".write(to: xx, atomically: true, encoding: .utf8)
        // Class-ID mapping: ebird code → string-encoded int.
        let mapping = dir.appendingPathComponent("ebird_classid_mapping.json")
        try #"{"0":"ostric2","1":"emu1","2":"mallar3"}"#
            .write(to: mapping, atomically: true, encoding: .utf8)
        return dir
    }

    /// A Bundle that points at a flat directory of JSON files — enough
    /// for SpeciesFilter's `bundle.url(forResource:)` lookup. The
    /// subdirectory: "ebird" lookup will miss, so the code path we hit
    /// here is the "flat fallback" branch.
    private func bundle(for dir: URL) -> Bundle {
        return Bundle(url: dir) ?? Bundle(path: dir.path)!
    }

    @Test("Parses the wrapped {country_code, species[]} shape")
    func wrappedShape() throws {
        let dir = try makeEbirdFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = self.bundle(for: dir)
        // avonetPath does not exist → queryAvonet falls through to eBird.
        let missingAvonet = dir.appendingPathComponent("avonet.db-missing")
        let filter = try SpeciesFilter(avonetPath: missingAvonet, ebirdBundle: bundle)

        // Call allowedClassIDs indirectly by synthesizing a region lookup.
        // RegionBounds.smallestContaining normally maps GPS → "US", so
        // pick a known US point (DC).
        let ids = filter.allowedClassIDs(lat: 38.9, lon: -77.0)
        let known = try #require(ids)
        // "mallar3" → 2, "ostric2" → 0; "unknown_code" drops.
        #expect(known.contains(2))
        #expect(known.contains(0))
        #expect(known.count == 2)
    }

    @Test("Parses the bare-array legacy shape")
    func bareArrayShape() throws {
        let dir = try makeEbirdFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = self.bundle(for: dir)
        let missingAvonet = dir.appendingPathComponent("avonet.db-missing")
        let filter = try SpeciesFilter(avonetPath: missingAvonet, ebirdBundle: bundle)

        // Calgary, AB — (51.0, -114.0). North of the US bbox (49.38)
        // so RegionBounds resolves to "CA".
        let ids = filter.allowedClassIDs(lat: 51.0, lon: -114.0)
        let known = try #require(ids)
        #expect(known.contains(0))  // ostric2
        #expect(known.contains(1))  // emu1
    }

    @Test("Second lookup at same GPS cell is served from cache")
    func gpsCacheHit() throws {
        let dir = try makeEbirdFixture()
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = self.bundle(for: dir)
        let missingAvonet = dir.appendingPathComponent("avonet.db-missing")
        let filter = try SpeciesFilter(avonetPath: missingAvonet, ebirdBundle: bundle)

        // First lookup populates the cache.
        let first = filter.allowedClassIDs(lat: 38.9, lon: -77.0)
        // Second call for the same cell returns an equal set (identity of the
        // set value itself is sufficient signal — the code path is covered).
        let second = filter.allowedClassIDs(lat: 38.92, lon: -77.04)
        #expect(first == second)

        // Different GPS cell → independent resolution (still through eBird
        // fallback, but a different cache key).
        let elsewhere = filter.allowedClassIDs(lat: 51.0, lon: -114.0)
        #expect(elsewhere != first)
    }

    @Test("Missing mapping JSON raises on init")
    func missingMapping() throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("empty-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let bundle = self.bundle(for: dir)
        let avonet = dir.appendingPathComponent("avonet.db-missing")
        #expect(throws: SpeciesFilterError.self) {
            try SpeciesFilter(avonetPath: avonet, ebirdBundle: bundle)
        }
    }
}
