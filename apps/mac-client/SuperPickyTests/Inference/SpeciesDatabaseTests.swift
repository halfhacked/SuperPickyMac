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

    /// Pinyin initials are derived from `chinese_simplified` and shipped in
    /// the bundled DB. A regression in the build or backfill step would
    /// silently leave the column NULL and break the initials-shorthand
    /// search (e.g. typing "bthd" to find 白头海雕).
    @Test("Bundled species DB exposes pinyin initials for known species")
    func pinyinInitialsPopulatedForKnownSpecies() throws {
        let url = try #require(SpeciesDatabase.bundledURL(),
                               "bundled bird_reference.sqlite is missing")
        let db = try SpeciesDatabase(url: url)

        let expected: [(english: String, initials: String)] = [
            ("Anna's Hummingbird", "asfn"),   // 安氏蜂鸟
            ("Bald Eagle", "bthd"),           // 白头海雕
            ("Golden Eagle", "jd"),           // 金雕
            // 鵟 is a rare CJK polyphone (kuáng/wáng); exercises the
            // DP-tokenizer / pypinyin-fallback path in the backfill, not
            // the common-character path above.
            ("Red-tailed Hawk", "hwk"),       // 红尾鵟
        ]
        for pair in expected {
            let match = (0..<InferenceConstants.oseaNumClasses)
                .lazy
                .compactMap { db.lookup(classID: $0) }
                .first { $0.englishName == pair.english }
            let entry = try #require(match, "\(pair.english) missing from bundled DB")
            #expect(entry.pinyinInitials == pair.initials,
                    "expected \(pair.english) initials \(pair.initials), got \(entry.pinyinInitials ?? "nil")")
        }
    }

    /// Users who think in Chinese species names can type the first letter of
    /// each pinyin syllable as a shorthand. The initials-prefix match must
    /// surface the expected species ahead of unrelated substring matches.
    @Test("search finds species by pinyin initials shorthand")
    func searchByPinyinInitials() throws {
        let url = try #require(SpeciesDatabase.bundledURL())
        let db = try SpeciesDatabase(url: url)

        // Full initials hit.
        let bald = db.search(query: "bthd")
        #expect(bald.contains { $0.englishName == "Bald Eagle" })

        // Prefix of initials also hits (user is still typing).
        let golden = db.search(query: "jd")
        #expect(golden.contains { $0.englishName == "Golden Eagle" })

        // Matching is case-insensitive.
        let annaUpper = db.search(query: "ASFN")
        #expect(annaUpper.contains { $0.englishName == "Anna's Hummingbird" })
    }

    /// Initials matching is prefix-only — a 2-letter substring of the
    /// middle of an initials string shouldn't match. Otherwise a query
    /// like "sh" would drown the results in unrelated hits.
    @Test("pinyin initials matching is prefix-only, not substring")
    func searchByInitialsIsPrefixOnly() throws {
        let url = try #require(SpeciesDatabase.bundledURL())
        let db = try SpeciesDatabase(url: url)

        // "fn" is the tail of Anna's Hummingbird initials "asfn". A
        // substring-based implementation would match; a prefix-based one
        // won't (unless some other species legitimately has initials
        // starting with "fn" and matches on its own merits).
        let results = db.search(query: "fn")
        #expect(!results.contains { $0.englishName == "Anna's Hummingbird" })
    }
}
