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

    @Test func burstAssignedByHighestConfidence() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let burstID = UUID()
        // 3 photos: 2 Unidentified, 1 Eagle with high confidence — Eagle wins
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

        #expect(eagle != nil)
        #expect(eagle?.burstGroups.count == 1)
        #expect(eagle?.burstGroups.first?.count == 3) // global count

        #expect(unidentified != nil)
        #expect(unidentified?.burstGroups.isEmpty == true)
    }

    @Test func burstWithTwoSpeciesUsesHigherConfidence() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let burstID = UUID()
        // Eagle at 0.6, Hawk at 0.9 — Hawk wins
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
        #expect(eagle?.burstGroups.isEmpty == true)
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

        // Filter singles for Eagle
        appState.sidebarSelection = .singles("Eagle")
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

        let unidentifiedName = appState.speciesEntries.first { $0.isUnidentified }?.name ?? "Unidentified"
        appState.sidebarSelection = .singles(unidentifiedName)
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
}
