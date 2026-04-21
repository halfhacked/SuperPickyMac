import Testing
import Foundation
@testable import SuperPicky

@Suite(.serialized) struct SpeciesHierarchyTests {

    // MARK: - Helper

    private func makeTempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makePhoto(
        folder: URL,
        filename: String = "IMG_\(UUID().uuidString).CR3",
        speciesCommonName: String? = nil,
        speciesScientificName: String? = nil,
        speciesConfidence: Float? = nil,
        burstGroupID: UUID? = nil,
        isBurstBest: Bool = false,
        starRating: Int = 0
    ) -> Photo {
        var photo = Photo(
            filename: filename,
            filePath: folder.appendingPathComponent(filename).path,
            folderPath: folder.path
        )
        photo.speciesCommonName = speciesCommonName
        photo.speciesScientificName = speciesScientificName
        photo.speciesConfidence = speciesConfidence
        photo.burstGroupID = burstGroupID
        photo.isBurstBest = isBurstBest
        photo.starRating = starRating
        return photo
    }

    private func setupDB(folder: URL, photos: [Photo]) throws {
        let db = try ReportDatabase(folderPath: folder)
        for var photo in photos {
            try db.save(&photo)
        }
    }

    // MARK: - Burst count uses global size

    @Test func burstWithMixedUnidentifiedAndTaggedMembersAppearsUnderBoth() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let burstID = UUID()
        // 3 photos: 2 Unidentified, 1 Eagle. The burst is tagged with
        // both "Unidentified" and "Eagle" across its members, so it must
        // appear under BOTH sidebar buckets with the full burst size.
        let photos = [
            makePhoto(folder: folder, burstGroupID: burstID),
            makePhoto(folder: folder, burstGroupID: burstID),
            makePhoto(folder: folder, speciesCommonName: "Eagle", speciesScientificName: "Aquila", speciesConfidence: 0.95, burstGroupID: burstID),
        ]
        try setupDB(folder: folder, photos: photos)

        let appState = AppState()
        appState.loadPhotos(for: folder)

        let eagle = appState.speciesEntries.first { $0.name == "Eagle" }
        let unidentified = appState.speciesEntries.first { $0.isUnidentified }

        #expect(eagle?.burstGroups.count == 1)
        #expect(eagle?.burstGroups.first?.count == 3) // global count

        #expect(unidentified?.burstGroups.count == 1)
        #expect(unidentified?.burstGroups.first?.count == 3)
        #expect(eagle?.burstGroups.first?.id == unidentified?.burstGroups.first?.id)
    }

    @Test func burstWithDifferentSpeciesPerMemberAppearsUnderBoth() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let burstID = UUID()
        // Member A tagged Eagle, member B tagged Hawk (different primaries
        // per member — can happen pre-fan-out or with non-fanned edits).
        // The burst appears under BOTH Eagle and Hawk.
        let photos = [
            makePhoto(folder: folder, speciesCommonName: "Eagle", speciesScientificName: "Aquila", speciesConfidence: 0.6, burstGroupID: burstID),
            makePhoto(folder: folder, speciesCommonName: "Hawk", speciesScientificName: "Accipiter", speciesConfidence: 0.9, burstGroupID: burstID),
        ]
        try setupDB(folder: folder, photos: photos)

        let appState = AppState()
        appState.loadPhotos(for: folder)

        let hawk = appState.speciesEntries.first { $0.name == "Hawk" }
        let eagle = appState.speciesEntries.first { $0.name == "Eagle" }

        #expect(hawk?.burstGroups.count == 1)
        #expect(hawk?.burstGroups.first?.count == 2)
        #expect(eagle?.burstGroups.count == 1)
        #expect(eagle?.burstGroups.first?.count == 2)
        #expect(hawk?.burstGroups.first?.id == eagle?.burstGroups.first?.id)
    }

    @Test func burstAllUnidentifiedStaysUnidentified() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let burstID = UUID()
        let photos = [
            makePhoto(folder: folder, burstGroupID: burstID),
            makePhoto(folder: folder, burstGroupID: burstID),
        ]
        try setupDB(folder: folder, photos: photos)

        let appState = AppState()
        appState.loadPhotos(for: folder)

        let unidentified = appState.speciesEntries.first { $0.isUnidentified }
        #expect(unidentified?.burstGroups.count == 1)
        #expect(unidentified?.burstGroups.first?.count == 2)
    }

    // MARK: - Singles count is correct

    @Test func singlesCountExcludesBurstPhotos() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let burstID = UUID()
        let photos = [
            makePhoto(folder: folder, speciesCommonName: "Eagle", speciesScientificName: "Aquila", burstGroupID: burstID),
            makePhoto(folder: folder, speciesCommonName: "Eagle", speciesScientificName: "Aquila", burstGroupID: burstID),
            makePhoto(folder: folder, speciesCommonName: "Eagle", speciesScientificName: "Aquila"), // single
            makePhoto(folder: folder, speciesCommonName: "Eagle", speciesScientificName: "Aquila"), // single
            makePhoto(folder: folder, speciesCommonName: "Eagle", speciesScientificName: "Aquila"), // single
        ]
        try setupDB(folder: folder, photos: photos)

        let appState = AppState()
        appState.loadPhotos(for: folder)

        let eagle = appState.speciesEntries.first { $0.name == "Eagle" }
        #expect(eagle?.singlePhotos == 3)
        #expect(eagle?.burstGroups.count == 1)
        #expect(eagle?.burstGroups.first?.count == 2)
        #expect(eagle?.count == 5) // total photos for species
    }

    // MARK: - Filter: burst group shows all photos in group

    @Test func burstGroupFilterShowsAllPhotosAcrossSpecies() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let burstID = UUID()
        let photos = [
            makePhoto(folder: folder, speciesCommonName: "Eagle", speciesScientificName: "Aquila", burstGroupID: burstID),
            makePhoto(folder: folder, burstGroupID: burstID), // unidentified
        ]
        try setupDB(folder: folder, photos: photos)

        let appState = AppState()
        appState.loadPhotos(for: folder)

        // Select burst group
        appState.sidebarSelection = .burstGroup(burstID)
        appState.applyFilter()

        #expect(appState.photos.count == 2)
    }

    // MARK: - Filter: singles shows only non-burst photos of that species

    @Test func singlesFilterShowsOnlyNonBurstPhotosOfSpecies() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let burstID = UUID()
        let photos = [
            makePhoto(folder: folder, speciesCommonName: "Eagle", speciesScientificName: "Aquila", burstGroupID: burstID),
            makePhoto(folder: folder, speciesCommonName: "Eagle", speciesScientificName: "Aquila"), // single
            makePhoto(folder: folder, speciesCommonName: "Hawk", speciesScientificName: "Accipiter"), // different species single
            makePhoto(folder: folder), // unidentified single
        ]
        try setupDB(folder: folder, photos: photos)

        let appState = AppState()
        appState.loadPhotos(for: folder)

        // Filter singles for Eagle (bucket key is the scientific name because
        // no eBird code is set on test SpeciesMatch entries).
        appState.sidebarSelection = .singles("Aquila")
        appState.applyFilter()

        #expect(appState.photos.count == 1)
        #expect(appState.photos.first?.speciesCommonName == "Eagle")
        #expect(appState.photos.first?.burstGroupID == nil)
    }

    @Test func singlesFilterForUnidentified() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let burstID = UUID()
        let photos = [
            makePhoto(folder: folder, burstGroupID: burstID), // unidentified burst
            makePhoto(folder: folder), // unidentified single
            makePhoto(folder: folder), // unidentified single
            makePhoto(folder: folder, speciesCommonName: "Eagle", speciesScientificName: "Aquila"), // different species
        ]
        try setupDB(folder: folder, photos: photos)

        let appState = AppState()
        appState.loadPhotos(for: folder)

        // Unidentified bucket is keyed by `nil`, not by a display string.
        appState.sidebarSelection = .singles(nil)
        appState.applyFilter()

        #expect(appState.photos.count == 2)
        #expect(appState.photos.allSatisfy { $0.speciesScientificName == nil && $0.burstGroupID == nil })
    }

    // MARK: - Sort order

    @Test func defaultSortIsAlphabeticalByName() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        // Zebra has higher count than Albatross — alphabetical still puts Albatross first.
        let photos = [
            makePhoto(folder: folder, speciesCommonName: "Zebra Finch", speciesScientificName: "Taeniopygia"),
            makePhoto(folder: folder, speciesCommonName: "Zebra Finch", speciesScientificName: "Taeniopygia"),
            makePhoto(folder: folder, speciesCommonName: "Zebra Finch", speciesScientificName: "Taeniopygia"),
            makePhoto(folder: folder, speciesCommonName: "Albatross", speciesScientificName: "Diomedea"),
            makePhoto(folder: folder, speciesCommonName: "Mockingbird", speciesScientificName: "Mimus"),
        ]
        try setupDB(folder: folder, photos: photos)

        let appState = AppState()
        appState.loadPhotos(for: folder)

        let identified = appState.speciesEntries.filter { !$0.isUnidentified }.map(\.name)
        #expect(identified == ["Albatross", "Mockingbird", "Zebra Finch"])
    }

    @Test func nameSortUsesDisplayNameAndLocale() throws {
        // Chinese names: 白鹭 (bái), 雕 (diāo), 鹰 (yīng).
        // Pinyin order: bái < diāo < yīng → Egret, Eagle, Hawk.
        // Feed English names in reverse alphabetical order to prove the
        // displayName + zh-Hans locale (not the English name) drives sort.
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let entries = [
            SpeciesEntry(speciesID: "hawk", scientificName: "Accipiter", name: "Hawk", cnName: "鹰", count: 1, burstGroups: [], singlePhotos: 1, isUnidentified: false),
            SpeciesEntry(speciesID: "eagle", scientificName: "Aquila", name: "Eagle", cnName: "雕", count: 1, burstGroups: [], singlePhotos: 1, isUnidentified: false),
            SpeciesEntry(speciesID: "egret", scientificName: "Egretta", name: "Egret", cnName: "白鹭", count: 1, burstGroups: [], singlePhotos: 1, isUnidentified: false),
        ]

        let sorted = SpeciesHierarchyBuilder.sorted(
            entries: entries,
            by: .name,
            displayName: { $0.cnName ?? $0.name },
            locale: Locale(identifier: "zh-Hans")
        )

        #expect(sorted.map(\.name) == ["Egret", "Eagle", "Hawk"])
    }

    @Test func countSortPutsLargestFirst() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let photos = [
            makePhoto(folder: folder, speciesCommonName: "Albatross", speciesScientificName: "Diomedea"),
            makePhoto(folder: folder, speciesCommonName: "Zebra Finch", speciesScientificName: "Taeniopygia"),
            makePhoto(folder: folder, speciesCommonName: "Zebra Finch", speciesScientificName: "Taeniopygia"),
            makePhoto(folder: folder, speciesCommonName: "Zebra Finch", speciesScientificName: "Taeniopygia"),
        ]
        try setupDB(folder: folder, photos: photos)

        let appState = AppState()
        appState.speciesSortOrder = .count
        appState.loadPhotos(for: folder)

        let identified = appState.speciesEntries.filter { !$0.isUnidentified }.map(\.name)
        #expect(identified == ["Zebra Finch", "Albatross"])
    }

    // MARK: - Unidentified sorted first

    @Test func unidentifiedSpeciesSortedFirst() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let photos = [
            makePhoto(folder: folder, speciesCommonName: "Eagle", speciesScientificName: "Aquila"),
            makePhoto(folder: folder), // unidentified
        ]
        try setupDB(folder: folder, photos: photos)

        let appState = AppState()
        appState.loadPhotos(for: folder)

        #expect(appState.speciesEntries.first?.isUnidentified == true)
    }

    // MARK: - No burst groups when all singles

    @Test func noBurstGroupsWhenAllSingles() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let photos = [
            makePhoto(folder: folder, speciesCommonName: "Eagle", speciesScientificName: "Aquila"),
            makePhoto(folder: folder, speciesCommonName: "Eagle", speciesScientificName: "Aquila"),
        ]
        try setupDB(folder: folder, photos: photos)

        let appState = AppState()
        appState.loadPhotos(for: folder)

        let eagle = appState.speciesEntries.first { $0.name == "Eagle" }
        #expect(eagle?.burstGroups.isEmpty == true)
        #expect(eagle?.singlePhotos == 2)
    }

    // MARK: - Multi-species assignment

    @Test func photoWithTwoSpeciesAppearsInBothBuckets() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var photo = makePhoto(folder: folder)
        photo.assignedSpecies = [
            SpeciesMatch(scientificName: "Aquila", commonName: "Eagle",
                         confidence: 0.9, cnName: nil, pinyin: nil,
                         thresholdUsed: "gps", ebirdCode: "eagle"),
            SpeciesMatch(scientificName: "Accipiter", commonName: "Hawk",
                         confidence: 0.4, cnName: nil, pinyin: nil,
                         thresholdUsed: "country", ebirdCode: "hawk"),
        ]
        try setupDB(folder: folder, photos: [photo])

        let appState = AppState()
        appState.loadPhotos(for: folder)

        let eagle = appState.speciesEntries.first { $0.speciesID == "eagle" }
        let hawk = appState.speciesEntries.first { $0.speciesID == "hawk" }
        #expect(eagle?.count == 1)
        #expect(hawk?.count == 1)
        #expect(eagle?.singlePhotos == 1)
        #expect(hawk?.singlePhotos == 1)

        // Filtering by either bucket returns the same photo.
        appState.sidebarSelection = .species("eagle")
        appState.applyFilter()
        #expect(appState.photos.count == 1)

        appState.sidebarSelection = .species("hawk")
        appState.applyFilter()
        #expect(appState.photos.count == 1)
    }

    @Test func multiSpeciesBurstAppearsUnderEveryTaggedSpecies() throws {
        // Burst members each tagged primary=Eagle; one of them also carries
        // a secondary Hawk tag. The burst should appear under BOTH Eagle
        // and Hawk in the sidebar so the secondary bucket isn't an empty
        // drill-down.
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let burstID = UUID()
        var a = makePhoto(folder: folder, filename: "A.CR3", burstGroupID: burstID)
        a.assignedSpecies = [
            SpeciesMatch(scientificName: "Aquila", commonName: "Eagle",
                         confidence: 0.95, cnName: nil, pinyin: nil,
                         thresholdUsed: "gps", ebirdCode: "eagle"),
        ]
        var b = makePhoto(folder: folder, filename: "B.CR3", burstGroupID: burstID)
        b.assignedSpecies = [
            SpeciesMatch(scientificName: "Aquila", commonName: "Eagle",
                         confidence: 0.92, cnName: nil, pinyin: nil,
                         thresholdUsed: "gps", ebirdCode: "eagle"),
            SpeciesMatch(scientificName: "Accipiter", commonName: "Hawk",
                         confidence: 0.30, cnName: nil, pinyin: nil,
                         thresholdUsed: "country", ebirdCode: "hawk"),
        ]
        try setupDB(folder: folder, photos: [a, b])

        let appState = AppState()
        appState.loadPhotos(for: folder)

        let eagle = appState.speciesEntries.first { $0.speciesID == "eagle" }
        let hawk = appState.speciesEntries.first { $0.speciesID == "hawk" }

        // Both buckets show the burst with the full burst size.
        #expect(eagle?.burstGroups.count == 1)
        #expect(eagle?.burstGroups.first?.count == 2)
        #expect(hawk?.burstGroups.count == 1)
        #expect(hawk?.burstGroups.first?.count == 2)
        #expect(eagle?.burstGroups.first?.id == hawk?.burstGroups.first?.id)

        // Bucket-level count: Eagle counts both members (both tagged Eagle);
        // Hawk counts only the member actually tagged Hawk.
        #expect(eagle?.count == 2)
        #expect(hawk?.count == 1)
    }

    @Test func twoSpeciesWithSameDisplayNameStayDistinct() throws {
        // Safety net for the "never key by display name" rule: two species
        // sharing the same common name but different eBird codes must show
        // up as two buckets, not one merged entry.
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var a = makePhoto(folder: folder, filename: "IMG_A.CR3")
        a.assignedSpecies = [SpeciesMatch(scientificName: "Species A", commonName: "Sparrow",
                                           confidence: 0.8, cnName: nil, pinyin: nil,
                                           thresholdUsed: "gps", ebirdCode: "sparow_a")]
        var b = makePhoto(folder: folder, filename: "IMG_B.CR3")
        b.assignedSpecies = [SpeciesMatch(scientificName: "Species B", commonName: "Sparrow",
                                           confidence: 0.8, cnName: nil, pinyin: nil,
                                           thresholdUsed: "gps", ebirdCode: "sparow_b")]
        try setupDB(folder: folder, photos: [a, b])

        let appState = AppState()
        appState.loadPhotos(for: folder)

        let sparrowBuckets = appState.speciesEntries.filter { $0.name == "Sparrow" }
        #expect(sparrowBuckets.count == 2)
        #expect(Set(sparrowBuckets.compactMap(\.speciesID)) == Set(["sparow_a", "sparow_b"]))
    }
}
