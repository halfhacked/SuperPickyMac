import Testing
import Foundation
@testable import SuperPicky

/// Covers the multi-species assignment behaviour on `Photo` and the
/// `AppState` mutation APIs (`setPrimarySpecies` / `addSpecies` /
/// `removeSpecies` / `correctSpecies`) that back the new species edit
/// panel.
@Suite(.serialized) struct AssignedSpeciesTests {

    /// Wraps the legacy "set the full list" semantics in terms of the new
    /// set-based API: promote the head as primary, add the rest, then
    /// remove anything from the photo's prior list that isn't in `species`.
    /// Empty `species` removes every existing entry.
    private func setSpeciesList(_ appState: AppState, id: UUID, species: [SpeciesMatch]) {
        let existing = appState.photos.first(where: { $0.id == id })?.assignedSpecies ?? []
        if let primary = species.first {
            appState.setPrimarySpecies(ids: [id], species: primary)
            for sp in species.dropFirst() {
                appState.addSpecies(ids: [id], species: sp)
            }
            let newIDs = Set(species.map(\.speciesID))
            for sp in existing where !newIDs.contains(sp.speciesID) {
                appState.removeSpecies(ids: [id], species: sp)
            }
        } else {
            for sp in existing {
                appState.removeSpecies(ids: [id], species: sp)
            }
        }
    }

    // MARK: - Helpers

    private func makeTempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func makePhoto(folder: URL, filename: String = "IMG_\(UUID().uuidString).CR3") -> Photo {
        Photo(
            filename: filename,
            filePath: folder.appendingPathComponent(filename).path,
            folderPath: folder.path
        )
    }

    private func match(sci: String, common: String?, ebird: String? = nil,
                       cn: String? = nil, conf: Float = 0.9,
                       threshold: String? = nil) -> SpeciesMatch {
        SpeciesMatch(
            scientificName: sci, commonName: common, confidence: conf,
            cnName: cn, pinyin: nil, thresholdUsed: threshold, ebirdCode: ebird
        )
    }

    /// Seed a fresh folder + DB with a 3-photo burst (all sharing `burstID`)
    /// plus one solo photo (no burst group). Returns the folder URL, the
    /// burst member IDs (in seed order), and the solo photo's ID. Callers
    /// are responsible for deleting the folder.
    private func seedBurstAndSolo(
        burstPrimary: SpeciesMatch
    ) throws -> (folder: URL, burstIDs: [UUID], soloID: UUID) {
        let folder = try makeTempFolder()
        let db = try ReportDatabase(folderPath: folder)

        let burstID = UUID()
        var burstIDs: [UUID] = []
        for i in 0..<3 {
            var p = makePhoto(folder: folder, filename: "burst_\(i).CR3")
            p.burstGroupID = burstID
            p.assignedSpecies = [burstPrimary]
            try db.save(&p)
            burstIDs.append(p.id)
        }

        var solo = makePhoto(folder: folder, filename: "solo.CR3")
        solo.assignedSpecies = [burstPrimary]
        try db.save(&solo)

        return (folder, burstIDs, solo.id)
    }

    // MARK: - SpeciesMatch identity

    @Test func speciesIDPrefersEbirdCodeOverScientificName() {
        let m = match(sci: "Aquila chrysaetos", common: "Golden Eagle", ebird: "goleag")
        #expect(m.speciesID == "goleag")
    }

    @Test func speciesIDFallsBackToScientificNameWhenNoEbirdCode() {
        let m = match(sci: "Custom Species", common: "My Bird")
        #expect(m.speciesID == "Custom Species")
    }

    @Test func speciesMatchDecodesEbirdCodeFromJSON() throws {
        let json = """
        {"name": "Aquila chrysaetos", "common_name": "Golden Eagle",
         "confidence": 0.9, "ebird_code": "goleag"}
        """.data(using: .utf8)!
        let m = try JSONDecoder().decode(SpeciesMatch.self, from: json)
        #expect(m.ebirdCode == "goleag")
        #expect(m.speciesID == "goleag")
    }

    // MARK: - Photo.assignedSpecies accessor

    @Test func assignedSpeciesSetterMirrorsPrimaryIntoScalarColumns() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var photo = makePhoto(folder: folder)
        let primary = match(sci: "Aquila chrysaetos", common: "Golden Eagle",
                            ebird: "goleag", cn: "金雕", conf: 0.92)
        photo.assignedSpecies = [primary]

        #expect(photo.speciesScientificName == "Aquila chrysaetos")
        #expect(photo.speciesCommonName == "Golden Eagle")
        #expect(photo.speciesCnName == "金雕")
        #expect(photo.speciesConfidence == 0.92)
        #expect(photo.assignedSpeciesJSON != nil)
    }

    @Test func assignedSpeciesGetterRoundTripsList() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var photo = makePhoto(folder: folder)
        let list = [
            match(sci: "Aquila", common: "Eagle", ebird: "eagle"),
            match(sci: "Accipiter", common: "Hawk", ebird: "hawk"),
        ]
        photo.assignedSpecies = list
        let decoded = photo.assignedSpecies
        #expect(decoded.count == 2)
        #expect(decoded.map(\.speciesID) == ["eagle", "hawk"])
        #expect(decoded.first?.commonName == "Eagle")
    }

    @Test func assignedSpeciesSetterEmptyClearsScalarColumns() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var photo = makePhoto(folder: folder)
        photo.assignedSpecies = [match(sci: "Aquila", common: "Eagle", ebird: "eagle")]
        #expect(photo.speciesCommonName == "Eagle")

        photo.assignedSpecies = []
        #expect(photo.speciesScientificName == nil)
        #expect(photo.speciesCommonName == nil)
        #expect(photo.speciesCnName == nil)
        #expect(photo.speciesPinyin == nil)
        #expect(photo.speciesConfidence == nil)
        // Persisted so the getter doesn't re-synthesize from the now-nil scalars.
        #expect(photo.assignedSpeciesJSON == "[]")
    }

    @Test func assignedSpeciesGetterFallsBackToScalarColumnsWhenJSONIsNil() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        var photo = makePhoto(folder: folder)
        photo.speciesCommonName = "Robin"
        photo.speciesScientificName = "Turdus migratorius"
        photo.speciesConfidence = 0.7
        // assignedSpeciesJSON stays nil — simulates a pre-v8 row.
        #expect(photo.assignedSpeciesJSON == nil)

        let list = photo.assignedSpecies
        #expect(list.count == 1)
        #expect(list.first?.scientificName == "Turdus migratorius")
        #expect(list.first?.commonName == "Robin")
        #expect(list.first?.confidence == 0.7)
        #expect(list.first?.ebirdCode == nil)
    }

    @Test func assignedSpeciesFallbackSynthesizesFromCommonNameOnly() {
        var photo = Photo(filename: "x.CR3", filePath: "/tmp/x.CR3", folderPath: "/tmp")
        photo.speciesCommonName = "Robin"
        let list = photo.assignedSpecies
        #expect(list.count == 1)
        // Scientific name is missing — the getter derives a stable slot from
        // the common name so `speciesID` isn't empty.
        #expect(list.first?.scientificName == "Robin")
        #expect(list.first?.speciesID == "Robin")
    }

    @Test func assignedSpeciesFallbackEmptyWhenAllScalarNil() {
        let photo = Photo(filename: "x.CR3", filePath: "/tmp/x.CR3", folderPath: "/tmp")
        #expect(photo.assignedSpecies.isEmpty)
    }

    // MARK: - Photo.inheritSpecies

    @Test func inheritSpeciesCopiesAssignedSpeciesJSON() {
        var donor = Photo(filename: "d.CR3", filePath: "/tmp/d.CR3", folderPath: "/tmp")
        donor.assignedSpecies = [
            match(sci: "Aquila", common: "Eagle", ebird: "eagle"),
            match(sci: "Accipiter", common: "Hawk", ebird: "hawk"),
        ]

        var recipient = Photo(filename: "r.CR3", filePath: "/tmp/r.CR3", folderPath: "/tmp")
        recipient.inheritSpecies(from: donor)

        #expect(recipient.assignedSpeciesJSON == donor.assignedSpeciesJSON)
        #expect(recipient.assignedSpecies.map(\.speciesID) == ["eagle", "hawk"])
        // Scalar mirrors come along too.
        #expect(recipient.speciesCommonName == "Eagle")
    }

    // MARK: - AppState.setAssignedSpecies

    @Test func setAssignedSpeciesPersistsToDB() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let db = try ReportDatabase(folderPath: folder)
        var photo = makePhoto(folder: folder, filename: "seed.CR3")
        photo.assignedSpecies = [match(sci: "Aquila", common: "Eagle", ebird: "eagle")]
        try db.save(&photo)

        let appState = AppState()
        appState.loadPhotos(for: folder)

        let hawk = match(sci: "Accipiter", common: "Hawk", ebird: "hawk")
        setSpeciesList(appState, id: photo.id, species: [
            match(sci: "Aquila", common: "Eagle", ebird: "eagle"),
            hawk,
        ])

        // DB round-trip: refetch via a fresh database handle.
        let db2 = try ReportDatabase(folderPath: folder)
        let fetched = try db2.fetchPhoto(id: photo.id)
        let refetched = try #require(fetched)
        #expect(refetched.assignedSpecies.count == 2)
        #expect(refetched.assignedSpecies.map(\.speciesID) == ["eagle", "hawk"])
    }

    @Test func setAssignedSpeciesUpdatesSidebarBuckets() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let db = try ReportDatabase(folderPath: folder)
        var photo = makePhoto(folder: folder, filename: "seed.CR3")
        photo.assignedSpecies = [match(sci: "Aquila", common: "Eagle", ebird: "eagle")]
        try db.save(&photo)

        let appState = AppState()
        appState.loadPhotos(for: folder)
        #expect(appState.speciesEntries.contains { $0.speciesID == "eagle" })
        #expect(!appState.speciesEntries.contains { $0.speciesID == "hawk" })

        setSpeciesList(appState, id: photo.id, species: [
            match(sci: "Aquila", common: "Eagle", ebird: "eagle"),
            match(sci: "Accipiter", common: "Hawk", ebird: "hawk"),
        ])

        #expect(appState.speciesEntries.contains { $0.speciesID == "eagle" })
        #expect(appState.speciesEntries.contains { $0.speciesID == "hawk" })
    }

    @Test func setAssignedSpeciesEmptyMovesPhotoToUnidentified() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let db = try ReportDatabase(folderPath: folder)
        var photo = makePhoto(folder: folder, filename: "seed.CR3")
        photo.assignedSpecies = [match(sci: "Aquila", common: "Eagle", ebird: "eagle")]
        try db.save(&photo)

        let appState = AppState()
        appState.loadPhotos(for: folder)
        setSpeciesList(appState, id: photo.id, species: [])

        appState.sidebarSelection = .species(nil) // Unidentified bucket
        appState.applyFilter()
        #expect(appState.photos.count == 1)

        appState.sidebarSelection = .species("eagle")
        appState.applyFilter()
        #expect(appState.photos.isEmpty)
    }

    // MARK: - AppState.correctSpecies (inline rename shim)

    @Test func correctSpeciesRenamesCommonNameWithoutChangingSpeciesID() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let db = try ReportDatabase(folderPath: folder)
        var photo = makePhoto(folder: folder, filename: "seed.CR3")
        photo.assignedSpecies = [match(sci: "Aquila chrysaetos",
                                        common: "Bald Eagle", // deliberately wrong
                                        ebird: "goleag")]
        try db.save(&photo)

        let appState = AppState()
        appState.loadPhotos(for: folder)
        appState.correctSpecies(ids: [photo.id], commonName: "Golden Eagle")

        let db2 = try ReportDatabase(folderPath: folder)
        let fetched = try db2.fetchPhoto(id: photo.id)
        let refetched = try #require(fetched)
        #expect(refetched.assignedSpecies.first?.commonName == "Golden Eagle")
        // Stable identity preserved — the sidebar bucket shouldn't jump.
        #expect(refetched.assignedSpecies.first?.speciesID == "goleag")
        #expect(refetched.assignedSpecies.first?.scientificName == "Aquila chrysaetos")
    }

    @Test func correctSpeciesOnUnidentifiedPhotoCreatesCustomEntry() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let db = try ReportDatabase(folderPath: folder)
        var photo = makePhoto(folder: folder, filename: "seed.CR3")
        try db.save(&photo)

        let appState = AppState()
        appState.loadPhotos(for: folder)
        appState.correctSpecies(ids: [photo.id], commonName: "Mystery Bird")

        let db2 = try ReportDatabase(folderPath: folder)
        let fetched = try db2.fetchPhoto(id: photo.id)
        let refetched = try #require(fetched)
        #expect(refetched.assignedSpecies.count == 1)
        #expect(refetched.assignedSpecies.first?.commonName == "Mystery Bird")
        #expect(refetched.assignedSpecies.first?.ebirdCode == nil)
        // Fallback: scientific name == typed text when OSEA has no match.
        #expect(refetched.assignedSpecies.first?.scientificName == "Mystery Bird")
    }

    // MARK: - photoHasSpeciesID via .species(...) filter

    @Test func speciesFilterMatchesAnyAssignedEntry() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let db = try ReportDatabase(folderPath: folder)
        var a = makePhoto(folder: folder, filename: "a.CR3")
        a.assignedSpecies = [match(sci: "Aquila", common: "Eagle", ebird: "eagle")]
        var b = makePhoto(folder: folder, filename: "b.CR3")
        b.assignedSpecies = [
            match(sci: "Aquila", common: "Eagle", ebird: "eagle"),
            match(sci: "Accipiter", common: "Hawk", ebird: "hawk"),
        ]
        var c = makePhoto(folder: folder, filename: "c.CR3")
        c.assignedSpecies = [match(sci: "Accipiter", common: "Hawk", ebird: "hawk")]
        for var p in [a, b, c] { try db.save(&p) }

        let appState = AppState()
        appState.loadPhotos(for: folder)

        appState.sidebarSelection = .species("eagle")
        appState.applyFilter()
        #expect(appState.photos.count == 2) // a + b

        appState.sidebarSelection = .species("hawk")
        appState.applyFilter()
        #expect(appState.photos.count == 2) // b + c
    }

    // MARK: - Burst fan-out

    @Test func setAssignedSpeciesFansOutToAllBurstMembers() throws {
        let seeded = try seedBurstAndSolo(
            burstPrimary: match(sci: "Aquila", common: "Eagle", ebird: "eagle")
        )
        defer { try? FileManager.default.removeItem(at: seeded.folder) }

        let appState = AppState()
        appState.loadPhotos(for: seeded.folder)

        // Edit the species list on ONE burst member; expect all three to
        // receive the new list while the solo photo stays untouched.
        let newList = [
            match(sci: "Accipiter", common: "Hawk", ebird: "hawk"),
            match(sci: "Buteo", common: "Buzzard", ebird: "buzzard"),
        ]
        setSpeciesList(appState, id: seeded.burstIDs[0], species: newList)

        let db = try ReportDatabase(folderPath: seeded.folder)
        for id in seeded.burstIDs {
            let fetched = try #require(try db.fetchPhoto(id: id))
            #expect(fetched.assignedSpecies.map(\.speciesID) == ["hawk", "buzzard"])
        }
        let solo = try #require(try db.fetchPhoto(id: seeded.soloID))
        #expect(solo.assignedSpecies.map(\.speciesID) == ["eagle"])
    }

    @Test func correctSpeciesFansOutToAllBurstMembers() throws {
        let seeded = try seedBurstAndSolo(
            burstPrimary: match(sci: "Aquila chrysaetos",
                                common: "Bald Eagle", // deliberately wrong
                                ebird: "goleag")
        )
        defer { try? FileManager.default.removeItem(at: seeded.folder) }

        let appState = AppState()
        appState.loadPhotos(for: seeded.folder)

        appState.correctSpecies(ids: [seeded.burstIDs[0]], commonName: "Golden Eagle")

        let db = try ReportDatabase(folderPath: seeded.folder)
        for id in seeded.burstIDs {
            let fetched = try #require(try db.fetchPhoto(id: id))
            let primary = try #require(fetched.assignedSpecies.first)
            #expect(primary.commonName == "Golden Eagle")
            // Stable identity preserved — sidebar bucket must not jump.
            #expect(primary.speciesID == "goleag")
            #expect(primary.scientificName == "Aquila chrysaetos")
        }
        let solo = try #require(try db.fetchPhoto(id: seeded.soloID))
        #expect(solo.assignedSpecies.first?.commonName == "Bald Eagle")
    }

    @Test func setAssignedSpeciesOnSoloPhotoDoesNotTouchOtherPhotos() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let db = try ReportDatabase(folderPath: folder)
        let eagle = match(sci: "Aquila", common: "Eagle", ebird: "eagle")

        var solo = makePhoto(folder: folder, filename: "solo.CR3")
        solo.assignedSpecies = [eagle]
        try db.save(&solo)

        var other = makePhoto(folder: folder, filename: "other.CR3")
        other.assignedSpecies = [eagle]
        try db.save(&other)

        let appState = AppState()
        appState.loadPhotos(for: folder)

        let hawk = match(sci: "Accipiter", common: "Hawk", ebird: "hawk")
        setSpeciesList(appState, id: solo.id, species: [hawk])

        let db2 = try ReportDatabase(folderPath: folder)
        let soloAfter = try #require(try db2.fetchPhoto(id: solo.id))
        let otherAfter = try #require(try db2.fetchPhoto(id: other.id))
        #expect(soloAfter.assignedSpecies.map(\.speciesID) == ["hawk"])
        #expect(otherAfter.assignedSpecies.map(\.speciesID) == ["eagle"])
    }

    @Test func burstFanOutWithSecondarySpeciesAppearsUnderBothSidebarBuckets() throws {
        // Start with a burst where every member is tagged Eagle.
        // Edit one member's species list to [Eagle, Hawk] — fan-out
        // propagates [Eagle, Hawk] to every burst member. The sidebar
        // hierarchy then shows the burst under BOTH Eagle and Hawk.
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }

        let db = try ReportDatabase(folderPath: folder)
        let eagle = match(sci: "Aquila", common: "Eagle", ebird: "eagle")

        let burstID = UUID()
        var burstIDs: [UUID] = []
        for i in 0..<3 {
            var p = makePhoto(folder: folder, filename: "burst_\(i).CR3")
            p.burstGroupID = burstID
            p.assignedSpecies = [eagle]
            try db.save(&p)
            burstIDs.append(p.id)
        }

        let appState = AppState()
        appState.loadPhotos(for: folder)

        let hawk = match(sci: "Accipiter", common: "Hawk", ebird: "hawk")
        setSpeciesList(appState, id: burstIDs[0], species: [eagle, hawk])

        let eagleEntry = appState.speciesEntries.first { $0.speciesID == "eagle" }
        let hawkEntry = appState.speciesEntries.first { $0.speciesID == "hawk" }
        #expect(eagleEntry?.burstGroups.count == 1)
        #expect(eagleEntry?.burstGroups.first?.count == 3)
        #expect(hawkEntry?.burstGroups.count == 1)
        #expect(hawkEntry?.burstGroups.first?.count == 3)
        #expect(eagleEntry?.burstGroups.first?.id == burstID)
        #expect(hawkEntry?.burstGroups.first?.id == burstID)
    }
}
