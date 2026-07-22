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

    private func signature(_ entries: [SpeciesEntry]) -> [String] {
        entries.map { entry in
            let bursts = entry.burstGroups
                .map { "\($0.id.uuidString):\($0.count):\($0.pickCount):\($0.bestFilename ?? "")" }
                .sorted()
                .joined(separator: ",")
            return [
                entry.id,
                entry.scientificName ?? "",
                entry.name,
                entry.cnName ?? "",
                String(entry.count),
                String(entry.picks),
                String(entry.singlePhotos),
                String(entry.singlePicks),
                String(entry.isUnidentified),
                bursts,
            ].joined(separator: "|")
        }.sorted()
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

    // MARK: - exact batch species changes

    @Test func batchSpeciesChangeMatchesFullBuildForMultiSpeciesSingle() {
        let eagle = match("eagle")
        let hawk = match("hawk")
        let owl = match("owl")
        let original = photo(species: [eagle, hawk])
        let untouched = photo(species: [eagle])
        var updated = original
        updated.assignedSpecies = [hawk, owl]

        let incremental = SpeciesHierarchyBuilder.applySpeciesChanges(
            entries: SpeciesHierarchyBuilder.build(from: [original, untouched]),
            changes: [SpeciesHierarchyChange(previous: original, updated: updated)]
        )
        let rebuilt = SpeciesHierarchyBuilder.build(from: [updated, untouched])

        #expect(signature(incremental) == signature(rebuilt))
    }

    @Test func batchSpeciesChangeMatchesFullBuildForCompleteBurst() {
        let groupID = UUID()
        let eagle = match("eagle")
        let hawk = match("hawk")
        var first = photo(species: [eagle], burstGroupID: groupID)
        var second = photo(species: [eagle], burstGroupID: groupID)
        let third = photo(species: [hawk], burstGroupID: groupID)
        first.filename = "first.jpg"
        first.isBurstBest = true
        first.pickStatus = .picked
        second.filename = "second.jpg"

        var updatedFirst = first
        var updatedSecond = second
        updatedFirst.assignedSpecies = [eagle, hawk]
        updatedSecond.assignedSpecies = [eagle, hawk]

        let initialPhotos = [first, second, third]
        let updatedPhotos = [updatedFirst, updatedSecond, third]
        let incremental = SpeciesHierarchyBuilder.applySpeciesChanges(
            entries: SpeciesHierarchyBuilder.build(from: initialPhotos),
            changes: zip(initialPhotos, updatedPhotos).map {
                SpeciesHierarchyChange(previous: $0.0, updated: $0.1)
            }
        )
        let rebuilt = SpeciesHierarchyBuilder.build(from: updatedPhotos)

        #expect(signature(incremental) == signature(rebuilt))
    }

    @Test func batchSpeciesRenameUpdatesBucketMetadata() {
        let original = photo(species: [
            match("eagle", common: "Wrong Eagle", scientific: "Aquila")
        ])
        var updated = original
        updated.assignedSpecies = [
            match("eagle", common: "Golden Eagle", scientific: "Aquila")
        ]

        let incremental = SpeciesHierarchyBuilder.applySpeciesChanges(
            entries: SpeciesHierarchyBuilder.build(from: [original]),
            changes: [SpeciesHierarchyChange(previous: original, updated: updated)]
        )
        let rebuilt = SpeciesHierarchyBuilder.build(from: [updated])

        #expect(signature(incremental) == signature(rebuilt))
        #expect(incremental.first?.name == "Golden Eagle")
    }

    @Test func batchPrimaryReorderDoesNotChangeHierarchy() {
        let eagle = match("eagle")
        let hawk = match("hawk")
        let original = photo(species: [eagle, hawk])
        var updated = original
        updated.assignedSpecies = [hawk, eagle]

        let initial = SpeciesHierarchyBuilder.build(from: [original])
        let incremental = SpeciesHierarchyBuilder.applySpeciesChanges(
            entries: initial,
            changes: [SpeciesHierarchyChange(previous: original, updated: updated)]
        )

        #expect(signature(incremental) == signature(initial))
    }

    @Test func batchBurstRemovalMatchesFullBuildAndCreatesUnidentifiedBucket() {
        let groupID = UUID()
        let eagle = match("eagle")
        let first = photo(species: [eagle], burstGroupID: groupID)
        let second = photo(species: [eagle], burstGroupID: groupID)
        var updatedFirst = first
        var updatedSecond = second
        updatedFirst.assignedSpecies = []
        updatedSecond.assignedSpecies = []

        let original = [first, second]
        let updated = [updatedFirst, updatedSecond]
        let incremental = SpeciesHierarchyBuilder.applySpeciesChanges(
            entries: SpeciesHierarchyBuilder.build(from: original),
            changes: zip(original, updated).map {
                SpeciesHierarchyChange(previous: $0.0, updated: $0.1)
            }
        )
        let rebuilt = SpeciesHierarchyBuilder.build(from: updated)

        #expect(signature(incremental) == signature(rebuilt))
        #expect(incremental.first(where: \.isUnidentified)?.burstGroups.first?.count == 2)
    }
}
