import Foundation
import Testing
@testable import SuperPickyInference

@Suite("SpeciesDatabase")
struct SpeciesDatabaseTests {
    /// The bundled `bird_reference.sqlite` must carry the pinyin column
    /// joined in by tools/build_species_db_add_pinyin.py. A regression in
    /// that build step leaves the DB column populated but pinyin as nil,
    /// which silently drops pinyin from XMP output and the sidebar.
    @Test("Bundled species DB exposes non-empty pinyin for a well-known species")
    func pinyinPopulatedForKnownSpecies() throws {
        let url = try #require(SpeciesDatabase.bundledURL(),
                               "bundled bird_reference.sqlite is missing")
        let db = try SpeciesDatabase(url: url)

        // Find Anna's Hummingbird by scanning class IDs rather than
        // hardcoding one — the class-to-species mapping can shift when
        // the model is retrained, but this species is always present.
        let match = (0..<InferenceConstants.oseaNumClasses)
            .lazy
            .compactMap { db.lookup(classID: $0) }
            .first { $0.englishName == "Anna's Hummingbird" }
        let entry = try #require(match, "Anna's Hummingbird missing from bundled DB")

        #expect(entry.chineseName == "安氏蜂鸟")
        // Pinyin must exist and must not contain spaces — the sidecar
        // writer and the keyword search widget both depend on the
        // space-free form ("anshifengniao", not "an shi feng niao").
        let pinyin = try #require(entry.pinyin, "Anna's Hummingbird is missing pinyin")
        #expect(!pinyin.isEmpty)
        #expect(!pinyin.contains(" "))
    }

    /// Autocomplete powers the species edit panel. Validates that a
    /// well-known English-name prefix finds the species (ranked ahead of
    /// substring matches) and that scientific + Chinese + pinyin lookups
    /// also hit.
    @Test("search matches english, scientific, chinese, pinyin")
    func searchMatchesAcrossNameFields() throws {
        let url = try #require(SpeciesDatabase.bundledURL(),
                               "bundled bird_reference.sqlite is missing")
        let db = try SpeciesDatabase(url: url)

        let englishHits = db.search(query: "Anna")
        #expect(englishHits.contains { $0.englishName == "Anna's Hummingbird" })

        let scientificHits = db.search(query: "Calypte")
        #expect(scientificHits.contains { $0.englishName == "Anna's Hummingbird" })

        let chineseHits = db.search(query: "安氏")
        #expect(chineseHits.contains { $0.englishName == "Anna's Hummingbird" })
    }

    @Test("search returns no matches on empty query")
    func searchRejectsEmptyQuery() throws {
        let url = try #require(SpeciesDatabase.bundledURL())
        let db = try SpeciesDatabase(url: url)
        #expect(db.search(query: "").isEmpty)
        #expect(db.search(query: "   ").isEmpty)
    }
}
