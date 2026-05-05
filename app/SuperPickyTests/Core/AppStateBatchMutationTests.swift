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

    @discardableResult
    private func seedPhoto(filename: String, species: SpeciesMatch?, into folder: URL) throws -> Photo {
        let db = try ReportDatabase(folderPath: folder)
        var p = Photo(
            filename: filename,
            filePath: folder.appendingPathComponent(filename).path,
            folderPath: folder.path
        )
        if let species { p.assignedSpecies = [species] }
        try db.save(&p)
        return p
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
        _ = try seedPhoto(filename: "eagle.CR3", species: match("eagle"), into: folder)
        let p2 = try seedPhoto(filename: "hawk.CR3", species: match("hawk"), into: folder)

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
        _ = try seedPhoto(filename: "a.CR3", species: match("eagle"), into: folder)
        let p2 = try seedPhoto(filename: "b.CR3", species: match("eagle"), into: folder)

        let app = AppState()
        app.loadPhotos(for: folder)
        app.selection.click(p2.id, photos: app.photos)

        app.sidebarSelection = .species("eagle")
        app.applyFilter()

        #expect(app.selection.activeID == p2.id)
    }

    @Test func loadPhotosOnFolderSwitchDefersSelectionAndBumpsFilterToken() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try seedPhotos(3, into: folder)

        let app = AppState()
        let initialToken = app.filterToken
        app.loadPhotos(for: folder)

        #expect(app.selection.activeID == nil,
                "Folder switch should defer selection to the view layer")
        #expect(app.filterToken != initialToken,
                "Folder switch should bump filterToken so the view can react")
    }

    @Test func loadPhotosWithDeferSelectionBumpsTokenOnSameFolderReclick() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try seedPhotos(3, into: folder)

        let app = AppState()
        app.loadPhotos(for: folder)
        let tokenAfterInitialLoad = app.filterToken

        // Simulate a sidebar re-click on the already-loaded folder. The
        // sidebar selection wraps a `.folder(URL)` so the URL is the same;
        // without `deferSelection` this is a no-op for selection state and
        // the view's auto-select-first never fires.
        app.loadPhotos(for: folder, deferSelection: true)

        #expect(app.filterToken != tokenAfterInitialLoad,
                "Same-folder re-click with deferSelection must bump filterToken so the view re-selects display-first")
    }

    @Test func sameFolderReclickPreservesUndoStack() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)

        let app = AppState()
        app.loadPhotos(for: folder)
        app.setRating(ids: [ids[0]], rating: 5)
        #expect(app.undoStackSizeForTesting() == 1,
                "Setup: rating mutation should push one undo entry")

        // Re-click the same folder via the user-initiated path. The
        // pre-existing full-reload behavior wiped the undo stack on
        // every loadPhotos call; the no-op fast path keeps it intact.
        app.loadPhotos(for: folder, deferSelection: true)

        #expect(app.undoStackSizeForTesting() == 1,
                "Same-folder re-click must not wipe the undo stack")
    }

    @Test func applyFilterAutoSelectFirstFalseLeavesSelectionCleared() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try seedPhoto(filename: "eagle.CR3", species: match("eagle"), into: folder)
        _ = try seedPhoto(filename: "hawk.CR3", species: match("hawk"), into: folder)

        let app = AppState()
        app.loadPhotos(for: folder)
        app.selection.clear()
        app.sidebarSelection = .species("hawk")
        app.applyFilter(autoSelectFirst: false)

        #expect(app.photos.count == 1)
        #expect(app.selection.activeID == nil,
                "autoSelectFirst:false should leave selection cleared for the view to fill in")
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
