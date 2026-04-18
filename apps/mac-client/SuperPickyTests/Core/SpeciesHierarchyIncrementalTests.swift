import Testing
import Foundation
@testable import SuperPicky

/// Unit coverage for `SpeciesHierarchyBuilder.applyIncremental` — the pure
/// O(1) hierarchy-delta path used by `AppState.updateSpeciesHierarchy`
/// during ingest. These build `SpeciesEntry` / `Photo` values directly
/// (no DB, no AppState) and exercise the add / remove corners.
@Suite struct SpeciesHierarchyIncrementalTests {

    private func photo(species: [SpeciesMatch] = [], burstGroupID: UUID? = nil) -> Photo {
        var p = Photo(
            filename: "x.jpg",
            filePath: "/tmp/x.jpg",
            folderPath: "/tmp"
        )
        p.assignedSpecies = species
        p.burstGroupID = burstGroupID
        return p
    }

    private func match(_ ebird: String, common: String? = nil,
                       scientific: String? = nil, cn: String? = nil,
                       confidence: Float = 0.9) -> SpeciesMatch {
        SpeciesMatch(
            scientificName: scientific ?? "Genus \(ebird)",
            commonName: common ?? ebird.capitalized,
            confidence: confidence,
            cnName: cn,
            pinyin: nil,
            thresholdUsed: nil,
            ebirdCode: ebird
        )
    }

    // MARK: - add

    @Test func addToEmptyCreatesBucket() {
        let p = photo(species: [match("baleag", common: "Bald Eagle")])
        let entries = SpeciesHierarchyBuilder.applyIncremental(entries: [], adding: p)
        #expect(entries.count == 1)
        #expect(entries[0].speciesID == "baleag")
        #expect(entries[0].name == "Bald Eagle")
        #expect(entries[0].count == 1)
        #expect(entries[0].singlePhotos == 1)
        #expect(entries[0].isUnidentified == false)
    }

    @Test func addSecondPhotoSameSpeciesIncrementsExistingBucket() {
        let p1 = photo(species: [match("baleag", common: "Bald Eagle")])
        let p2 = photo(species: [match("baleag", common: "Bald Eagle")])
        var entries = SpeciesHierarchyBuilder.applyIncremental(entries: [], adding: p1)
        entries = SpeciesHierarchyBuilder.applyIncremental(entries: entries, adding: p2)
        #expect(entries.count == 1)
        #expect(entries[0].count == 2)
        #expect(entries[0].singlePhotos == 2)
    }

    @Test func addTwoDifferentSpeciesCreatesTwoBuckets() {
        let p1 = photo(species: [match("baleag", common: "Bald Eagle")])
        let p2 = photo(species: [match("osprey", common: "Osprey")])
        var entries = SpeciesHierarchyBuilder.applyIncremental(entries: [], adding: p1)
        entries = SpeciesHierarchyBuilder.applyIncremental(entries: entries, adding: p2)
        let ids = Set(entries.compactMap(\.speciesID))
        #expect(ids == ["baleag", "osprey"])
    }

    @Test func addWithEmptyAssignedGoesToUnidentifiedBucket() {
        let p = photo(species: [])
        let entries = SpeciesHierarchyBuilder.applyIncremental(entries: [], adding: p)
        #expect(entries.count == 1)
        #expect(entries[0].isUnidentified == true)
        #expect(entries[0].speciesID == nil)
    }

    @Test func addFillsInMissingScientificNameFromNewPrimary() {
        // First photo had no scientificName (custom entry); second photo
        // has the scientificName — bucket backfills.
        let p1Primary = SpeciesMatch(
            scientificName: "scifi_a",  // speciesID == scientificName when ebirdCode is nil
            commonName: "Sparrow",
            confidence: 0.5,
            cnName: nil, pinyin: nil,
            thresholdUsed: nil, ebirdCode: nil
        )
        // Same speciesID (scientificName fallback)
        let p2Primary = SpeciesMatch(
            scientificName: "scifi_a",
            commonName: "Sparrow",
            confidence: 0.5,
            cnName: "麻雀", pinyin: nil,
            thresholdUsed: nil, ebirdCode: nil
        )
        var entries = SpeciesHierarchyBuilder.applyIncremental(entries: [], adding: photo(species: [p1Primary]))
        #expect(entries[0].cnName == nil)  // first add had no cn
        entries = SpeciesHierarchyBuilder.applyIncremental(entries: entries, adding: photo(species: [p2Primary]))
        #expect(entries[0].cnName == "麻雀")  // second add backfills
    }

    // MARK: - remove

    @Test func removeLastOccurrenceDeletesBucket() {
        let p = photo(species: [match("baleag", common: "Bald Eagle")])
        var entries = SpeciesHierarchyBuilder.applyIncremental(entries: [], adding: p)
        #expect(entries.count == 1)
        entries = SpeciesHierarchyBuilder.applyIncremental(entries: entries, removing: p)
        #expect(entries.isEmpty)
    }

    @Test func removeOneOfTwoDecrementsCount() {
        let p1 = photo(species: [match("baleag", common: "Bald Eagle")])
        let p2 = photo(species: [match("baleag", common: "Bald Eagle")])
        var entries = SpeciesHierarchyBuilder.applyIncremental(entries: [], adding: p1)
        entries = SpeciesHierarchyBuilder.applyIncremental(entries: entries, adding: p2)
        entries = SpeciesHierarchyBuilder.applyIncremental(entries: entries, removing: p1)
        #expect(entries.count == 1)
        #expect(entries[0].count == 1)
        #expect(entries[0].singlePhotos == 1)
    }

    @Test func removeNonexistentBucketIsNoop() {
        // Remove a species that was never added — shouldn't crash, shouldn't
        // invent a bucket, should leave entries unchanged.
        let p = photo(species: [match("baleag")])
        let entries = SpeciesHierarchyBuilder.applyIncremental(entries: [], removing: p)
        #expect(entries.isEmpty)
    }

    @Test func removeKeepsBucketWhenBurstGroupsRemain() {
        // Simulate: bucket has count=1 but an associated burst group. The
        // incremental remove should leave the entry in place (with count
        // decremented) rather than deleting and losing the burst.
        let withBurst = SpeciesEntry(
            speciesID: "baleag",
            scientificName: "Haliaeetus leucocephalus",
            name: "Bald Eagle",
            cnName: nil,
            count: 1,
            burstGroups: [BurstGroupEntry(id: UUID(), count: 3, bestFilename: "b.jpg")],
            singlePhotos: 1,
            isUnidentified: false
        )
        let p = photo(species: [match("baleag", common: "Bald Eagle")])
        let entries = SpeciesHierarchyBuilder.applyIncremental(entries: [withBurst], removing: p)
        #expect(entries.count == 1)
        #expect(entries[0].count == 0)
        #expect(entries[0].burstGroups.count == 1)
    }

    // MARK: - combined

    @Test func removePlusAddMovesPhotoBetweenBuckets() {
        // Starting state: photo in "baleag" bucket. Remove it as "baleag"
        // and add it back as "osprey" — net effect should be baleag gone,
        // osprey created.
        let baldPhoto = photo(species: [match("baleag", common: "Bald Eagle")])
        let ospreyPhoto = photo(species: [match("osprey", common: "Osprey")])
        var entries = SpeciesHierarchyBuilder.applyIncremental(entries: [], adding: baldPhoto)
        entries = SpeciesHierarchyBuilder.applyIncremental(
            entries: entries,
            removing: baldPhoto,
            adding: ospreyPhoto
        )
        #expect(entries.count == 1)
        #expect(entries[0].speciesID == "osprey")
    }

    @Test func unidentifiedSentinelRoundTrips() {
        // Add an unidentified photo, then remove it via another unidentified
        // photo reference — removal should match the sentinel bucket.
        let a = photo(species: [])
        let b = photo(species: [])
        var entries = SpeciesHierarchyBuilder.applyIncremental(entries: [], adding: a)
        entries = SpeciesHierarchyBuilder.applyIncremental(entries: entries, adding: b)
        #expect(entries.count == 1)
        #expect(entries[0].count == 2)
        entries = SpeciesHierarchyBuilder.applyIncremental(entries: entries, removing: a)
        #expect(entries.count == 1)
        #expect(entries[0].isUnidentified == true)
        entries = SpeciesHierarchyBuilder.applyIncremental(entries: entries, removing: b)
        #expect(entries.isEmpty)
    }
}
