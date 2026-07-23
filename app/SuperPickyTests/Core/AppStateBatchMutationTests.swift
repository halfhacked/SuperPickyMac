import Testing
import Foundation
import AppKit
@testable import SuperPicky

@Suite(.serialized)
@MainActor
struct AppStateBatchMutationTests {

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

    // MARK: - setPickStatus(ids:status:)

    @Test func setPickStatusPicksAllSelectedPhotos() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        await app.setPickStatus(ids: Set(ids), status: .picked).value

        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            #expect(try db.fetchPhoto(id: id)?.pickStatus == .picked)
        }
        #expect(app.picksCount == 3)
        #expect(app.rejectedCount == 0)
    }

    @Test func setPickStatusIsIdempotent() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try #require(try seedPhotos(1, into: folder).first)
        let app = AppState()
        app.loadPhotos(for: folder)

        await app.setPickStatus(ids: [id], status: .picked).value
        await app.setPickStatus(ids: [id], status: .picked).value

        #expect(app.allPhotosForTesting().first?.pickStatus == .picked)
        #expect(app.undoStackSizeForTesting() == 1)
    }

    @Test func setPickStatusTransitionsRejectedPhotoToPicked() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try #require(try seedPhotos(1, into: folder).first)
        let app = AppState()
        app.loadPhotos(for: folder)

        await app.setPickStatus(ids: [id], status: .rejected).value
        await app.setPickStatus(ids: [id], status: .picked).value

        let photo = try #require(try ReportDatabase(folderPath: folder).fetchPhoto(id: id))
        #expect(photo.pickStatus == .picked)
        #expect(photo.isPicked)
        #expect(!photo.isRejected)
        #expect(app.picksCount == 1)
        #expect(app.rejectedCount == 0)
    }

    @Test func unflagClearsPickedAndRejectedPhotos() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(2, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        await app.setPickStatus(ids: [ids[0]], status: .picked).value
        await app.setPickStatus(ids: [ids[1]], status: .rejected).value
        await app.setPickStatus(ids: Set(ids), status: .unflagged).value

        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            #expect(try db.fetchPhoto(id: id)?.pickStatus == .unflagged)
        }
        #expect(app.picksCount == 0)
        #expect(app.rejectedCount == 0)
    }

    @Test func queuedFlagChangesHonorLatestRequestedStatus() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try #require(try seedPhotos(1, into: folder).first)
        let app = AppState()
        app.loadPhotos(for: folder)

        let pickTask = app.setPickStatus(ids: [id], status: .picked)
        let unflagTask = app.setPickStatus(ids: [id], status: .unflagged)
        await pickTask.value
        await unflagTask.value

        let photo = try #require(try ReportDatabase(folderPath: folder).fetchPhoto(id: id))
        #expect(photo.pickStatus == .unflagged)
        #expect(app.allPhotosForTesting().first?.pickStatus == .unflagged)
    }

    @Test func setPickStatusPushesOneUndoEntry() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        await app.setPickStatus(ids: Set(ids), status: .picked).value
        let stackSizeAfter = app.undoStackSizeForTesting()
        #expect(stackSizeAfter == 1)

        await app.undoLastAction().value
        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            #expect(try db.fetchPhoto(id: id)?.pickStatus == .unflagged)
        }
    }

    // MARK: - setRating(ids:rating:)

    @Test func setRatingAppliesToEveryID() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        await app.setRating(ids: Set(ids), rating: 4).value

        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            let photo = try db.fetchPhoto(id: id)
            #expect(photo?.starRating == 4)
            #expect(photo?.pickStatus == .unflagged)
        }
    }

    // MARK: - Rejected status

    @Test func rejectPreservesRatingFilterMembership() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)
        app.sidebarSelection = .rating(3)

        await app.setRating(ids: Set(ids), rating: 3).value
        app.applyFilter()
        #expect(app.photos.count == 3)

        await app.setPickStatus(ids: [ids[0]], status: .rejected).value
        #expect(app.photos.count == 3)
        #expect(app.photos.contains(where: { $0.id == ids[0] }))

        let rejected = try #require(try ReportDatabase(folderPath: folder).fetchPhoto(id: ids[0]))
        #expect(rejected.starRating == 3)
        #expect(rejected.isManualRating)
        #expect(rejected.pickStatus == .rejected)
        #expect(app.ratingCounts[3] == 3)
        #expect(app.rejectedCount == 1)
    }

    @Test func zeroRatingAndRejectionCanOverlap() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(2, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        await app.setRating(ids: [ids[0]], rating: 0).value
        await app.setPickStatus(ids: [ids[1]], status: .rejected).value

        app.sidebarSelection = .rating(0)
        app.applyFilter()
        #expect(Set(app.photos.map(\.id)) == Set(ids))

        let rejectedZero = try #require(
            try ReportDatabase(folderPath: folder).fetchPhoto(id: ids[1])
        )
        #expect(rejectedZero.starRating == 0)
        #expect(rejectedZero.pickStatus == .rejected)
        #expect(rejectedZero.isManualRating == false)

        app.sidebarSelection = .rejected
        app.applyFilter()
        #expect(app.photos.map(\.id) == [ids[1]])

        await app.setRating(ids: [ids[1]], rating: 4).value
        #expect(app.photos.map(\.id) == [ids[1]])
        #expect(app.ratingCounts[0] == 1)
        #expect(app.ratingCounts[4] == 1)
        #expect(app.rejectedCount == 1)

        let updated = try #require(try ReportDatabase(folderPath: folder).fetchPhoto(id: ids[1]))
        #expect(updated.starRating == 4)
        #expect(updated.pickStatus == .rejected)
    }

    @Test func undoRejectRestoresRatingAndRejectedState() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let id = try #require(try seedPhotos(1, into: folder).first)
        let app = AppState()
        app.loadPhotos(for: folder)

        await app.setRating(ids: [id], rating: 4).value
        await app.setPickStatus(ids: [id], status: .rejected).value
        app.sidebarSelection = .rating(4)
        app.applyFilter()
        #expect(app.photos.map(\.id) == [id])

        await app.undoLastAction().value

        let restored = try #require(try ReportDatabase(folderPath: folder).fetchPhoto(id: id))
        #expect(restored.starRating == 4)
        #expect(restored.pickStatus == .unflagged)
        #expect(app.photos.map(\.id) == [id])
    }

    @Test func deleteRejectedPhotosDeletesAllRejectedPhotosOnly() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try ReportDatabase(folderPath: folder)
        let fixtures = [
            (filename: "zero-rejected.CR3", rating: 0, rejected: true),
            (filename: "rated-rejected.CR3", rating: 4, rejected: true),
            (filename: "keep.CR3", rating: 0, rejected: false),
        ]
        var photos: [Photo] = []
        for fixture in fixtures {
            let url = folder.appendingPathComponent(fixture.filename)
            FileManager.default.createFile(atPath: url.path, contents: Data())
            var photo = Photo(
                filename: fixture.filename,
                filePath: url.path,
                folderPath: folder.path
            )
            photo.starRating = fixture.rating
            photo.pickStatus = fixture.rejected ? .rejected : .unflagged
            try db.save(&photo)
            photos.append(photo)
        }

        let app = AppState(trashPhoto: { url in
            try FileManager.default.removeItem(at: url)
        })
        app.loadPhotos(for: folder)
        app.sidebarSelection = .rejected
        app.applyFilter()
        #expect(app.photos.count == 2)

        await app.deleteRejectedPhotos().value

        let remaining = try db.fetchAllPhotos()
        #expect(remaining.map(\.filename) == ["keep.CR3"])
        #expect(app.allPhotosForTesting().map(\.filename) == ["keep.CR3"])
        #expect(app.photos.isEmpty)
        #expect(app.rejectedCount == 0)
        #expect(FileManager.default.fileExists(atPath: photos[2].filePath))
        #expect(!FileManager.default.fileExists(atPath: photos[0].filePath))
        #expect(!FileManager.default.fileExists(atPath: photos[1].filePath))
    }

    @Test func commandDeleteRecognizesBackspaceAndForwardDelete() {
        func event(
            characters: String = "",
            keyCode: UInt16 = 0,
            modifiers: NSEvent.ModifierFlags = []
        ) -> KeyboardMonitor.KeyEvent {
            KeyboardMonitor.KeyEvent(
                characters: characters,
                keyCode: keyCode,
                modifiers: modifiers,
                isEscape: false,
                isReturn: false,
                isLeftArrow: false,
                isRightArrow: false
            )
        }

        #expect(event(keyCode: 51, modifiers: .command).isCommandDelete)
        #expect(event(keyCode: 117, modifiers: .command).isCommandDelete)
        #expect(!event(keyCode: 51, modifiers: []).isCommandDelete)
        #expect(!event(keyCode: 0, modifiers: .command).isCommandDelete)
        #expect(event(characters: "p").photoPickStatus == .picked)
        #expect(event(characters: "u").photoPickStatus == .unflagged)
        #expect(event(characters: "x").photoPickStatus == .rejected)
        #expect(event(characters: "i").photoPickStatus == nil)
    }

    // MARK: - correctSpecies(ids:commonName:)

    @Test func correctSpeciesAppliesPrimaryRenameAcrossSelection() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        for id in ids {
            await app.setPrimarySpecies(ids: [id], species: match("eagle")).value
        }
        await app.correctSpecies(ids: Set(ids), commonName: "Bald Eagle").value

        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            let p = try db.fetchPhoto(id: id)!
            #expect(p.assignedSpecies.first?.commonName == "Bald Eagle")
        }
    }

    // MARK: - setPrimarySpecies(ids:species:)

    @Test func setPrimarySpeciesAddsWhenMissingAndPromotesWhenPresent() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        await app.addSpecies(ids: [ids[1]], species: match("hawk")).value
        await app.addSpecies(ids: [ids[1]], species: match("eagle")).value

        await app.setPrimarySpecies(ids: Set(ids), species: match("eagle")).value

        let db = try ReportDatabase(folderPath: folder)
        let p0 = try db.fetchPhoto(id: ids[0])!
        let p1 = try db.fetchPhoto(id: ids[1])!
        let p2 = try db.fetchPhoto(id: ids[2])!
        #expect(p0.assignedSpecies.first?.speciesID == "eagle")
        #expect(p1.assignedSpecies.first?.speciesID == "eagle")
        #expect(p2.assignedSpecies.first?.speciesID == "eagle")
    }

    // MARK: - addSpecies(ids:species:)

    @Test func addSpeciesIsIdempotentForExistingSpecies() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(2, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        await app.addSpecies(ids: Set(ids), species: match("eagle")).value
        await app.addSpecies(ids: Set(ids), species: match("eagle")).value

        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            let p = try db.fetchPhoto(id: id)!
            #expect(p.assignedSpecies.count == 1)
            #expect(p.assignedSpecies.first?.speciesID == "eagle")
        }
    }

    // MARK: - removeSpecies(ids:species:)

    @Test func removeSpeciesNoOpsWhenAbsent() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(2, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        await app.addSpecies(ids: [ids[0]], species: match("eagle")).value
        await app.removeSpecies(ids: Set(ids), species: match("hawk")).value

        let db = try ReportDatabase(folderPath: folder)
        let p0 = try db.fetchPhoto(id: ids[0])!
        let p1 = try db.fetchPhoto(id: ids[1])!
        #expect(p0.assignedSpecies.map(\.speciesID) == ["eagle"])
        #expect(p1.assignedSpecies.isEmpty)
    }

    @Test func removeSpeciesDropsFromEveryPhotoThatHasIt() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)
        await app.addSpecies(ids: Set(ids), species: match("eagle")).value

        await app.removeSpecies(ids: Set(ids), species: match("eagle")).value

        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            #expect(try db.fetchPhoto(id: id)!.assignedSpecies.isEmpty)
        }
    }

    @Test func addAndRemoveSpeciesRecordLatencyProfiles() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(2, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)
        let eagle = match("eagle")

        await app.addSpecies(ids: Set(ids), species: eagle).value
        let addProfile = try #require(app.lastSpeciesEditProfileForTesting())
        #expect(addProfile.operation == "add")
        #expect(addProfile.targetPhotoCount == 2)
        #expect(addProfile.changedPhotoCount == 2)
        #expect(addProfile.persistedPhotoCount == 2)

        await app.removeSpecies(ids: Set(ids), species: eagle).value
        let removeProfile = try #require(app.lastSpeciesEditProfileForTesting())
        #expect(removeProfile.operation == "remove")
        #expect(removeProfile.targetPhotoCount == 2)
        #expect(removeProfile.changedPhotoCount == 2)
        #expect(removeProfile.persistedPhotoCount == 2)
    }

    // MARK: - Burst fan-out

    @Test func setPrimarySpeciesFansOutToBurstMembers() async throws {
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

        await app.setPrimarySpecies(ids: [burstIDs[0]], species: match("eagle")).value

        for id in burstIDs {
            let p = try db.fetchPhoto(id: id)!
            #expect(p.assignedSpecies.first?.speciesID == "eagle")
        }
    }

    @Test func speciesEditReturnsBeforePersistenceCompletes() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try ReportDatabase(folderPath: folder)
        let burstID = UUID()
        var firstID: UUID?

        for i in 0..<200 {
            var photo = Photo(
                filename: "probe_\(i).CR3",
                filePath: folder.appendingPathComponent("probe_\(i).CR3").path,
                folderPath: folder.path
            )
            photo.burstGroupID = burstID
            try db.save(&photo)
            firstID = firstID ?? photo.id
        }

        let app = AppState()
        app.loadPhotos(for: folder)
        let start = ProcessInfo.processInfo.systemUptime
        let mutation = app.addSpecies(
            ids: [try #require(firstID)],
            species: match("eagle")
        )
        let elapsedMS = (ProcessInfo.processInfo.systemUptime - start) * 1_000
        #expect(elapsedMS < 100, "Species edit blocked the caller for \(elapsedMS) ms")

        await mutation.value
        let profile = try #require(app.lastSpeciesEditProfileForTesting())
        #expect(profile.operation == "add")
        #expect(profile.requestedPhotoCount == 1)
        #expect(profile.targetPhotoCount == 200)
        #expect(profile.changedPhotoCount == 200)
        #expect(profile.persistedPhotoCount == 200)
        #expect(profile.queuedXMPWriteCount == 200)
        #expect(!profile.persistenceFailed)
        // Immediate work is measured separately from deferred DB latency.
        #expect(profile.immediateMilliseconds >= profile.stateApplyMilliseconds)

        let photos = app.allPhotosForTesting()
        for i in 0..<200 {
            let photo = try #require(try db.fetchPhoto(
                id: photos[i].id
            ))
            #expect(photo.assignedSpecies.first?.speciesID == "eagle")
        }
        // XMP is write-behind — assert sidecars only after an explicit flush.
        await app.flushPendingPersistence()
        let sidecar = XMPWriter.sidecarURL(for: photos[0])
        let xmp = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(xmp.contains("Eagle"))
    }

    @Test func queuedSpeciesEditsCommitInCallOrder() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(1, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        let addEagle = app.addSpecies(ids: Set(ids), species: match("eagle"))
        let promoteHawk = app.setPrimarySpecies(ids: Set(ids), species: match("hawk"))
        await promoteHawk.value
        await addEagle.value

        let db = try ReportDatabase(folderPath: folder)
        let photo = try #require(try db.fetchPhoto(id: ids[0]))
        #expect(photo.assignedSpecies.map(\.speciesID) == ["hawk", "eagle"])
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

    @Test func sameFolderReclickPreservesUndoStack() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)

        let app = AppState()
        app.loadPhotos(for: folder)
        await app.setRating(ids: [ids[0]], rating: 5).value
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

    @Test func undoRestoresAssignedSpeciesAfterBatchEdit() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)
        await app.addSpecies(ids: Set(ids), species: match("eagle")).value

        await app.setPrimarySpecies(ids: Set(ids), species: match("hawk")).value
        await app.undoLastAction().value

        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            let p = try db.fetchPhoto(id: id)!
            #expect(p.assignedSpecies.map(\.speciesID) == ["eagle"])
        }
    }

    // MARK: - Optimistic (immediate) state visibility

    @Test func speciesEditUpdatesObservableStateBeforeTaskAwait() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(1, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        // Do NOT await — the observable arrays must already reflect the edit.
        let task = app.addSpecies(ids: Set(ids), species: match("eagle"))
        #expect(app.allPhotosForTesting().first?.assignedSpecies.first?.speciesID == "eagle")
        #expect(app.photos.first?.assignedSpecies.first?.speciesID == "eagle")
        #expect(app.speciesEntries.contains { $0.speciesID == "eagle" })

        await task.value
        let db = try ReportDatabase(folderPath: folder)
        #expect(try db.fetchPhoto(id: ids[0])?.assignedSpecies.first?.speciesID == "eagle")
    }

    @Test func speciesEditImmediateLatencyAtLargeLibraryScale() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let db = try ReportDatabase(folderPath: folder)
        var seeded = (0..<2_000).map { index in
            Photo(
                filename: "large_\(index).CR3",
                filePath: folder.appendingPathComponent("large_\(index).CR3").path,
                folderPath: folder.path
            )
        }
        try db.saveAll(&seeded)

        let app = AppState()
        app.loadPhotos(for: folder)
        let mutation = app.addSpecies(ids: [seeded[0].id], species: match("eagle"))
        let profile = try #require(app.lastSpeciesEditProfileForTesting())

        #expect(
            profile.immediateMilliseconds < 100,
            "Large-library species edit took \(profile.immediateMilliseconds) ms before returning"
        )

        await mutation.value
        await app.flushPendingPersistence()
    }

    @Test func rapidSpeciesEditsKeepOrderedStateWithoutStaleCompletion() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(1, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        let addEagle = app.addSpecies(ids: Set(ids), species: match("eagle"))
        let promoteHawk = app.setPrimarySpecies(ids: Set(ids), species: match("hawk"))
        // Synchronously the UI already shows both edits applied in call order.
        #expect(app.allPhotosForTesting().first?.assignedSpecies.map(\.speciesID) == ["hawk", "eagle"])

        await addEagle.value
        await promoteHawk.value
        // Deferred persistence never republishes stale rows over the UI.
        #expect(app.allPhotosForTesting().first?.assignedSpecies.map(\.speciesID) == ["hawk", "eagle"])
        let db = try ReportDatabase(folderPath: folder)
        #expect(try db.fetchPhoto(id: ids[0])?.assignedSpecies.map(\.speciesID) == ["hawk", "eagle"])
    }

    @Test func immediateUndoRevertsObservableStateBeforeAwait() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(1, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)
        await app.addSpecies(ids: Set(ids), species: match("eagle")).value

        let undo = app.undoLastAction()
        // Undo must revert observable state synchronously, before persistence.
        #expect(app.allPhotosForTesting().first?.assignedSpecies.isEmpty == true)
        #expect(!app.speciesEntries.contains { $0.speciesID == "eagle" })
        #expect(app.speciesEntries.first(where: \.isUnidentified)?.count == 1)

        await undo.value
        let db = try ReportDatabase(folderPath: folder)
        #expect(try db.fetchPhoto(id: ids[0])?.assignedSpecies.isEmpty == true)
    }

    // MARK: - Logical no-ops

    @Test func noOpSpeciesEditSkipsUndoDatabaseAndXMP() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(1, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)
        await app.addSpecies(ids: Set(ids), species: match("eagle")).value
        await app.flushPendingPersistence()

        let undoBefore = app.undoStackSizeForTesting()
        // Re-adding the same species is a logical no-op.
        await app.addSpecies(ids: Set(ids), species: match("eagle")).value

        #expect(app.undoStackSizeForTesting() == undoBefore)
        let profile = try #require(app.lastSpeciesEditProfileForTesting())
        #expect(profile.changedPhotoCount == 0)
        #expect(profile.persistedPhotoCount == 0)
        let pendingXMP = await app.pendingXMPWriteCountForTesting()
        #expect(pendingXMP == 0)
    }

    // MARK: - Write-behind XMP coalescing

    @Test func coalescedXMPWritesLatestSpeciesAfterFlush() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(1, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)
        let flushTokenBefore = app.speciesXMPFlushToken

        // Three rapid edits collapse to the final desired state.
        await app.addSpecies(ids: Set(ids), species: match("eagle")).value
        await app.removeSpecies(ids: Set(ids), species: match("eagle")).value
        await app.addSpecies(ids: Set(ids), species: match("hawk")).value

        // One coalesced sidecar per path — flush deterministically (no sleep).
        await app.flushPendingPersistence()
        let sidecar = XMPWriter.sidecarURL(for: app.allPhotosForTesting()[0])
        let xmp = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(xmp.contains("Hawk"))
        #expect(!xmp.contains("Eagle"))
        let pendingXMP = await app.pendingXMPWriteCountForTesting()
        #expect(pendingXMP == 0)
        #expect(app.speciesXMPFlushToken > flushTokenBefore)
    }

    @Test func removingSpeciesDeletesMatchingKeywordsAndPreservesUnrelatedKeywords() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let eagle = match("eagle")
        let photo = try seedPhoto(filename: "legacy.CR3", species: eagle, into: folder)
        let sidecar = XMPWriter.sidecarURL(for: photo)
        let legacy = """
        <?xml version="1.0" encoding="UTF-8"?>
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description
              xmlns:dc="http://purl.org/dc/elements/1.1/"
              xmlns:lr="http://ns.adobe.com/lightroom/1.0/">
              <dc:subject>
                <rdf:Bag>
                  <rdf:li>Portfolio</rdf:li>
                  <rdf:li>Eagle</rdf:li>
                  <rdf:li>Genus eagle</rdf:li>
                </rdf:Bag>
              </dc:subject>
              <lr:hierarchicalSubject>
                <rdf:Bag>
                  <rdf:li>Bird|Eagle</rdf:li>
                </rdf:Bag>
              </lr:hierarchicalSubject>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        try Data(legacy.utf8).write(to: sidecar)
        let app = AppState()
        app.loadPhotos(for: folder)

        await app.removeSpecies(ids: [photo.id], species: eagle).value
        await app.flushPendingPersistence()

        let content = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(content.contains("<rdf:li>Portfolio</rdf:li>"))
        #expect(!content.contains("<rdf:li>Eagle</rdf:li>"))
        #expect(!content.contains("<rdf:li>Genus eagle</rdf:li>"))
        #expect(!content.contains("<rdf:li>Bird|Eagle</rdf:li>"))
    }

    // MARK: - Retryable XMP failure

    @Test func xmpWriteFailureIsRetryableAndKeepsOptimisticState() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(1, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)
        await app.addSpecies(ids: Set(ids), species: match("eagle")).value

        // Block the sidecar path with a directory so the write-behind XMP fails.
        let sidecar = XMPWriter.sidecarURL(for: app.allPhotosForTesting()[0])
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)

        await app.flushPendingPersistence()
        #expect(app.hasSpeciesPersistenceFailure)
        // Optimistic state survives the failed write.
        #expect(app.allPhotosForTesting().first?.assignedSpecies.first?.speciesID == "eagle")

        // Clear the obstruction and retry — the pending XMP write drains.
        try FileManager.default.removeItem(at: sidecar)
        await app.retrySpeciesPersistence().value

        #expect(!app.hasSpeciesPersistenceFailure)
        let xmp = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(xmp.contains("Eagle"))
    }

    /// Regression: an XMP-only failure must stay durably represented in
    /// `AppState` so an unrelated successful edit cannot clear the retry banner
    /// while a failed sidecar is still pending. See handleXMPFlush /
    /// refreshSpeciesFailureMessage / failedXMPSidecars.
    @Test func retainedXMPFailureSurvivesUnrelatedSuccessAndClearsOnRetry() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(2, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        // Edit photo 0, then block its sidecar so only the write-behind XMP
        // fails (SQLite already committed).
        await app.addSpecies(ids: [ids[0]], species: match("eagle")).value
        let target = try #require(app.allPhotosForTesting().first { $0.id == ids[0] })
        let sidecar = XMPWriter.sidecarURL(for: target)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)

        await app.flushPendingPersistence()
        // XMP-only failure: no SQLite failure, exactly one retained sidecar.
        #expect(app.hasSpeciesPersistenceFailure)
        #expect(app.failedSpeciesEditCountForTesting() == 0)
        #expect(app.failedXMPSidecarCountForTesting() == 1)

        // An unrelated SUCCESSFUL species edit refreshes the banner state but
        // must NOT clear it while the failed sidecar is still pending.
        await app.addSpecies(ids: [ids[1]], species: match("hawk")).value
        #expect(app.hasSpeciesPersistenceFailure)
        #expect(app.failedXMPSidecarCountForTesting() == 1)

        // Fix the filesystem and retry — the retained failed sidecar drains and
        // the banner clears.
        try FileManager.default.removeItem(at: sidecar)
        await app.retrySpeciesPersistence().value

        #expect(!app.hasSpeciesPersistenceFailure)
        #expect(app.failedXMPSidecarCountForTesting() == 0)
        let xmp = try String(contentsOf: sidecar, encoding: .utf8)
        #expect(xmp.contains("Eagle"))
    }

    /// Deleting a photo with a retained XMP failure must evict it from both the
    /// write-behind queue and the durable failure state so no impossible retry
    /// (a sidecar for a now-trashed photo) remains.
    @Test func deletingPhotoEvictsRetainedXMPFailure() async throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(1, into: folder)
        // Delete trashes the underlying file, so it must actually exist.
        FileManager.default.createFile(
            atPath: folder.appendingPathComponent("p0.CR3").path, contents: Data()
        )
        let app = AppState()
        app.loadPhotos(for: folder)

        await app.addSpecies(ids: [ids[0]], species: match("eagle")).value
        let target = try #require(app.allPhotosForTesting().first { $0.id == ids[0] })
        let sidecar = XMPWriter.sidecarURL(for: target)
        try FileManager.default.createDirectory(at: sidecar, withIntermediateDirectories: true)

        await app.flushPendingPersistence()
        #expect(app.hasSpeciesPersistenceFailure)
        #expect(app.failedXMPSidecarCountForTesting() == 1)

        await app.deletePhoto(id: ids[0]).value
        #expect(!app.hasSpeciesPersistenceFailure)
        #expect(app.failedXMPSidecarCountForTesting() == 0)
        let pendingXMP = await app.pendingXMPWriteCountForTesting()
        #expect(pendingXMP == 0)
    }
}
