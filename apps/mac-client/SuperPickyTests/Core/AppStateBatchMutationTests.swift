import Testing
import Foundation
@testable import SuperPicky

@Suite(.serialized) struct AppStateBatchMutationTests {

    private func makeTempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func match(_ ebird: String, conf: Float = 0.9) -> SpeciesMatch {
        SpeciesMatch(
            scientificName: "Genus \(ebird)",
            commonName: ebird.capitalized,
            confidence: conf,
            cnName: nil, pinyin: nil,
            thresholdUsed: nil, ebirdCode: ebird
        )
    }

    private func seedPhotos(_ count: Int, into folder: URL) throws -> [UUID] {
        let db = try ReportDatabase(folderPath: folder)
        var ids: [UUID] = []
        for i in 0..<count {
            var p = Photo(
                filename: "p\(i).CR3",
                filePath: folder.appendingPathComponent("p\(i).CR3").path,
                folderPath: folder.path
            )
            try db.save(&p)
            ids.append(p.id)
        }
        return ids
    }

    // MARK: - setPick(ids:)

    @Test func setPickPicksAllWhenAnyUnpicked() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        app.setPick(ids: [ids[0]])
        let mixed = Set(ids[0...2])
        app.setPick(ids: mixed)

        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            #expect(try db.fetchPhoto(id: id)?.isPick == true)
        }
    }

    @Test func setPickUnpicksAllWhenAllPicked() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        let s = Set(ids)
        app.setPick(ids: s)
        app.setPick(ids: s)

        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            #expect(try db.fetchPhoto(id: id)?.isPick == false)
        }
    }

    @Test func setPickSinglePhotoMatchesLegacyToggleSemantics() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(1, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        app.setPick(ids: [ids[0]])
        #expect(app.allPhotosForTesting().first?.isPick == true)
        app.setPick(ids: [ids[0]])
        #expect(app.allPhotosForTesting().first?.isPick == false)
    }

    @Test func setPickPushesOneUndoEntry() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        app.setPick(ids: Set(ids))
        let stackSizeAfter = app.undoStackSizeForTesting()
        #expect(stackSizeAfter == 1)

        app.undoLastAction()
        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            #expect(try db.fetchPhoto(id: id)?.isPick == false)
        }
    }

    // MARK: - setRating(ids:rating:)

    @Test func setRatingAppliesToEveryID() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        app.setRating(ids: Set(ids), rating: 4)

        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            #expect(try db.fetchPhoto(id: id)?.starRating == 4)
        }
    }

    // MARK: - reject(ids:)

    @Test func rejectMakesPhotosLeaveFilteredArray() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)
        app.sidebarSelection = .rating(3)

        app.setRating(ids: Set(ids), rating: 3)
        app.applyFilter()
        #expect(app.photos.count == 3)

        app.reject(ids: [ids[0]])
        #expect(app.photos.count == 2)
        #expect(!app.photos.contains(where: { $0.id == ids[0] }))
    }

    // MARK: - correctSpecies(ids:commonName:)

    @Test func correctSpeciesAppliesPrimaryRenameAcrossSelection() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        for id in ids {
            app.setPrimarySpecies(ids: [id], species: match("eagle"))
        }
        app.correctSpecies(ids: Set(ids), commonName: "Bald Eagle")

        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            let p = try db.fetchPhoto(id: id)!
            #expect(p.assignedSpecies.first?.commonName == "Bald Eagle")
        }
    }

    // MARK: - setPrimarySpecies(ids:species:)

    @Test func setPrimarySpeciesAddsWhenMissingAndPromotesWhenPresent() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        app.addSpecies(ids: [ids[1]], species: match("hawk"))
        app.addSpecies(ids: [ids[1]], species: match("eagle"))

        app.setPrimarySpecies(ids: Set(ids), species: match("eagle"))

        let db = try ReportDatabase(folderPath: folder)
        let p0 = try db.fetchPhoto(id: ids[0])!
        let p1 = try db.fetchPhoto(id: ids[1])!
        let p2 = try db.fetchPhoto(id: ids[2])!
        #expect(p0.assignedSpecies.first?.speciesID == "eagle")
        #expect(p1.assignedSpecies.first?.speciesID == "eagle")
        #expect(p2.assignedSpecies.first?.speciesID == "eagle")
    }

    // MARK: - addSpecies(ids:species:)

    @Test func addSpeciesIsIdempotentForExistingSpecies() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(2, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        app.addSpecies(ids: Set(ids), species: match("eagle"))
        app.addSpecies(ids: Set(ids), species: match("eagle"))

        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            let p = try db.fetchPhoto(id: id)!
            #expect(p.assignedSpecies.count == 1)
            #expect(p.assignedSpecies.first?.speciesID == "eagle")
        }
    }

    // MARK: - removeSpecies(ids:species:)

    @Test func removeSpeciesNoOpsWhenAbsent() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(2, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        app.addSpecies(ids: [ids[0]], species: match("eagle"))
        app.removeSpecies(ids: Set(ids), species: match("hawk"))

        let db = try ReportDatabase(folderPath: folder)
        let p0 = try db.fetchPhoto(id: ids[0])!
        let p1 = try db.fetchPhoto(id: ids[1])!
        #expect(p0.assignedSpecies.map(\.speciesID) == ["eagle"])
        #expect(p1.assignedSpecies.isEmpty)
    }

    @Test func removeSpeciesDropsFromEveryPhotoThatHasIt() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)
        app.addSpecies(ids: Set(ids), species: match("eagle"))

        app.removeSpecies(ids: Set(ids), species: match("eagle"))

        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            #expect(try db.fetchPhoto(id: id)!.assignedSpecies.isEmpty)
        }
    }

    // MARK: - Burst fan-out

    @Test func setPrimarySpeciesFansOutToBurstMembers() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try ReportDatabase(folderPath: folder)

        let burstID = UUID()
        var burstIDs: [UUID] = []
        for i in 0..<3 {
            var p = Photo(filename: "burst_\(i).CR3",
                          filePath: folder.appendingPathComponent("burst_\(i).CR3").path,
                          folderPath: folder.path)
            p.burstGroupID = burstID
            try db.save(&p)
            burstIDs.append(p.id)
        }

        let app = AppState()
        app.loadPhotos(for: folder)

        app.setPrimarySpecies(ids: [burstIDs[0]], species: match("eagle"))

        for id in burstIDs {
            let p = try db.fetchPhoto(id: id)!
            #expect(p.assignedSpecies.first?.speciesID == "eagle")
        }
    }

    // MARK: - applyFilter() auto-selects first when nothing remains active

    @Test func applyFilterAutoSelectsFirstWhenSelectionEmpty() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try ReportDatabase(folderPath: folder)

        var p1 = Photo(filename: "eagle.CR3",
                       filePath: folder.appendingPathComponent("eagle.CR3").path,
                       folderPath: folder.path)
        p1.assignedSpecies = [match("eagle")]
        try db.save(&p1)

        var p2 = Photo(filename: "hawk.CR3",
                       filePath: folder.appendingPathComponent("hawk.CR3").path,
                       folderPath: folder.path)
        p2.assignedSpecies = [match("hawk")]
        try db.save(&p2)

        let app = AppState()
        app.loadPhotos(for: folder)
        app.selection.clear()

        app.sidebarSelection = .species("hawk")
        app.applyFilter()

        #expect(app.photos.count == 1)
        #expect(app.selection.activeID == p2.id)
    }

    @Test func applyFilterPreservesActiveWhenStillInFilter() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try ReportDatabase(folderPath: folder)

        var p1 = Photo(filename: "a.CR3",
                       filePath: folder.appendingPathComponent("a.CR3").path,
                       folderPath: folder.path)
        p1.assignedSpecies = [match("eagle")]
        try db.save(&p1)

        var p2 = Photo(filename: "b.CR3",
                       filePath: folder.appendingPathComponent("b.CR3").path,
                       folderPath: folder.path)
        p2.assignedSpecies = [match("eagle")]
        try db.save(&p2)

        let app = AppState()
        app.loadPhotos(for: folder)
        app.selection.click(p2.id, photos: app.photos)

        app.sidebarSelection = .species("eagle")
        app.applyFilter()

        #expect(app.selection.activeID == p2.id)
    }

    // MARK: - Undo restores species

    @Test func undoRestoresAssignedSpeciesAfterBatchEdit() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)
        app.addSpecies(ids: Set(ids), species: match("eagle"))

        app.setPrimarySpecies(ids: Set(ids), species: match("hawk"))
        app.undoLastAction()

        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            let p = try db.fetchPhoto(id: id)!
            #expect(p.assignedSpecies.map(\.speciesID) == ["eagle"])
        }
    }
}
