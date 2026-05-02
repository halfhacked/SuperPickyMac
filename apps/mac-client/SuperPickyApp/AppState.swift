import SwiftUI
import os

enum SidebarSelection: Hashable {
    case folder(URL)
    case rating(Int)
    case flying
    case picks
    /// Species bucket keyed by stable `SpeciesMatch.speciesID` (eBird code
    /// or scientific-name fallback). `nil` selects the Unidentified bucket.
    case species(String?)
    case burstGroup(UUID)
    /// Singles under a species, keyed by the same stable ID as `.species`.
    case singles(String?)
}

/// Species with its burst groups for the sidebar hierarchy.
///
/// `speciesID` is the stable identity (eBird code or scientific name); all
/// filter / selection comparisons go through it. `name` is the English
/// common name used as both the default display label and the input to
/// `CullingConfig.localizedName(en:cn:)` for runtime-localized rendering.
struct SpeciesEntry: Identifiable {
    let speciesID: String?
    let scientificName: String?
    let name: String
    let cnName: String?
    let count: Int
    let picks: Int
    let burstGroups: [BurstGroupEntry]
    let singlePhotos: Int
    let singlePicks: Int
    let isUnidentified: Bool
    var id: String { speciesID ?? "__unidentified__" }

    init(speciesID: String?, scientificName: String?, name: String, cnName: String?,
         count: Int, picks: Int = 0, burstGroups: [BurstGroupEntry],
         singlePhotos: Int, singlePicks: Int = 0, isUnidentified: Bool) {
        self.speciesID = speciesID
        self.scientificName = scientificName
        self.name = name
        self.cnName = cnName
        self.count = count
        self.picks = picks
        self.burstGroups = burstGroups
        self.singlePhotos = singlePhotos
        self.singlePicks = singlePicks
        self.isUnidentified = isUnidentified
    }
}

struct BurstGroupEntry: Identifiable {
    let id: UUID
    let count: Int
    let pickCount: Int
    let bestFilename: String?

    init(id: UUID, count: Int, pickCount: Int = 0, bestFilename: String?) {
        self.id = id
        self.count = count
        self.pickCount = pickCount
        self.bestFilename = bestFilename
    }
}

@Observable
final class AppState {
    private let logger = Logger(subsystem: "com.halfhacked.superpicky", category: "AppState")

    var sidebarSelection: SidebarSelection?
    let selection = PhotoSelection()

    /// Back-compat accessor. Reads/writes `selection.activeID`. New code
    /// should use `selection` directly.
    var selectedPhotoID: UUID? {
        get { selection.activeID }
        set {
            if let id = newValue {
                selection.click(id, photos: photos)
            } else {
                selection.clear()
            }
        }
    }
    var folders: [URL] = []
    var speciesEntries: [SpeciesEntry] = []
    var speciesSortOrder: SpeciesSortOrder = .name
    /// Closure to derive the display name used for alphabetical sort.
    /// MainView wires this to `config.localizedName(...)` so the order
    /// matches whatever the user sees. Default preserves the English
    /// name for unit tests that don't plumb config.
    var speciesDisplayName: (SpeciesEntry) -> String = { $0.name }
    /// Locale used for alphabetical comparison — drives ICU collation
    /// (e.g. pinyin for `zh-Hans`, gojūon for `ja`).
    var speciesSortLocale: Locale = .current

    /// Autocomplete backend used by the species edit panel. MainView wires
    /// this to `SpeciesDatabase.search(query:limit:)` once at startup so the
    /// UI never depends directly on `SuperPickyInference` types.
    /// Default returns no matches, which keeps unit tests self-contained.
    @ObservationIgnored var speciesSearch: (_ query: String) -> [SpeciesMatch] = { _ in [] }

    var ratingCounts: [Int: Int] {
        var counts: [Int: Int] = [:]
        for p in allPhotos { counts[p.starRating, default: 0] += 1 }
        return counts
    }
    var flyingCount: Int { allPhotos.lazy.filter(\.isFlying).count }
    var picksCount: Int { allPhotos.lazy.filter(\.isPick).count }

    struct UndoAction {
        struct Entry {
            let photoID: UUID
            let previousRating: Int
            let previousIsPick: Bool
            let previousIsManualRating: Bool
            let previousAssignedSpecies: [SpeciesMatch]
            let wasHidden: Bool
        }
        let entries: [Entry]
    }

    // All photos from the current folder (unfiltered)
    private var allPhotos: [Photo] = []
    var pickedPhotos: [Photo] { allPhotos.filter { $0.isPick } }
    // Filtered photos shown in the UI
    var photos: [Photo] = []
    // O(1) lookup from photo.id → index in allPhotos and photos. Keeping
    // these in sync with the arrays turns `appendProcessedPhoto` from
    // O(N) per call into O(1); on a 9 000-photo import the main thread
    // was otherwise spending O(N²) total doing linear scans per update,
    // which is what made scrolling and clicks feel frozen during a run.
    private var allPhotoIndex: [UUID: Int] = [:]
    private var filteredPhotoIndex: [UUID: Int] = [:]

    private func rebuildAllPhotoIndex() {
        allPhotoIndex.removeAll(keepingCapacity: true)
        allPhotoIndex.reserveCapacity(allPhotos.count)
        for (i, p) in allPhotos.enumerated() { allPhotoIndex[p.id] = i }
    }

    private func rebuildFilteredPhotoIndex() {
        filteredPhotoIndex.removeAll(keepingCapacity: true)
        filteredPhotoIndex.reserveCapacity(photos.count)
        for (i, p) in photos.enumerated() { filteredPhotoIndex[p.id] = i }
    }
    private var undoStack: [UndoAction] = []
    private static let maxUndoDepth = 20
    var canUndo: Bool { !undoStack.isEmpty }

    private var cachedDB: ReportDatabase?

    // Per-folder processing state
    var processingFolder: URL?
    var processingProgress: Double = 0
    var processingProcessed: Int = 0
    var processingTotal: Int = 0
    var currentFolder: URL?
    var isProcessing: Bool { processingFolder != nil }

    var selectedPhoto: Photo? {
        guard let id = selection.activeID else { return nil }
        return photos.first { $0.id == id }
    }

    var isEmpty: Bool {
        folders.isEmpty || allPhotos.isEmpty
    }

    private func db() throws -> ReportDatabase {
        if let db = cachedDB { return db }
        guard let folder = currentFolder else { throw CocoaError(.fileNoSuchFile) }
        let db = try ReportDatabase(folderPath: folder)
        cachedDB = db
        return db
    }

    /// Load photos from the database for the selected folder.
    /// Preserves current filter and selection when possible.
    /// Pass `skipHierarchy: true` during incremental processing to avoid O(n²) rebuilds.
    func loadPhotos(for folder: URL, skipHierarchy: Bool = false) {
        let isFolderSwitch = (currentFolder != folder)
        currentFolder = folder
        cachedDB = nil
        undoStack = []
        if isFolderSwitch { selection.clear() }
        do {
            let database = try ReportDatabase(folderPath: folder)
            cachedDB = database
            allPhotos = try database.fetchAllPhotos()
            rebuildAllPhotoIndex()
            if !skipHierarchy {
                buildSpeciesHierarchy()
            }

            // Re-apply current filter instead of resetting to all
            applyFilter()

            if isFolderSwitch {
                let paths = allPhotos.map(\.filePath)
                MainActor.assumeIsolated {
                    PreviewSweepCoordinator.shared.start(folder: folder, paths: paths)
                    PrefetchCoordinator.shared.reset()
                }
            }
        } catch {
            logger.error("loadPhotos failed: \(error)")
            allPhotos = []
            photos = []
            allPhotoIndex = [:]
            filteredPhotoIndex = [:]
            speciesEntries = []
        }
    }

    /// Build species → burst group hierarchy from loaded photos.
    private func buildSpeciesHierarchy() {
        speciesEntries = SpeciesHierarchyBuilder.build(
            from: allPhotos,
            sortOrder: speciesSortOrder,
            displayName: speciesDisplayName,
            locale: speciesSortLocale
        )
    }

    /// Re-sort the current hierarchy in place. Cheap — no rebuild.
    func resortSpeciesEntries() {
        speciesEntries = SpeciesHierarchyBuilder.sorted(
            entries: speciesEntries,
            by: speciesSortOrder,
            displayName: speciesDisplayName,
            locale: speciesSortLocale
        )
    }

    /// Incrementally append or replace a single processed photo. Hot
    /// path during folder processing — runs in O(1) in the common case
    /// (photo updates in place) via the two index dicts. Leaving the
    /// current filter is the only path that does an O(M) index fix-up.
    func appendProcessedPhoto(_ photo: Photo) {
        let oldPhoto: Photo?
        if let idx = allPhotoIndex[photo.id] {
            oldPhoto = allPhotos[idx]
            allPhotos[idx] = photo
        } else {
            oldPhoto = nil
            allPhotoIndex[photo.id] = allPhotos.count
            allPhotos.append(photo)
        }

        updateSpeciesHierarchy(removing: oldPhoto, adding: photo)

        let matches = photoMatchesCurrentFilter(photo)
        if let fIdx = filteredPhotoIndex[photo.id] {
            if matches {
                photos[fIdx] = photo
            } else {
                // Leaving filter — remove and reindex the rest.
                photos.remove(at: fIdx)
                filteredPhotoIndex.removeValue(forKey: photo.id)
                for (id, i) in filteredPhotoIndex where i > fIdx {
                    filteredPhotoIndex[id] = i - 1
                }
            }
        } else if matches {
            filteredPhotoIndex[photo.id] = photos.count
            photos.append(photo)
        }
    }

    /// O(1) incremental update. Burst reassignment (dominant species can
    /// flip across members) is skipped here and materialized by the full
    /// rebuild in `loadPhotos` at end-of-run; during ingest, burst
    /// members show under their own species and burst groups don't
    /// appear in the sidebar.
    private func updateSpeciesHierarchy(removing old: Photo?, adding photo: Photo) {
        let updated = SpeciesHierarchyBuilder.applyIncremental(
            entries: speciesEntries,
            removing: old,
            adding: photo
        )
        speciesEntries = SpeciesHierarchyBuilder.sorted(
            entries: updated,
            by: speciesSortOrder,
            displayName: speciesDisplayName,
            locale: speciesSortLocale
        )
    }

    private func photoMatchesCurrentFilter(_ photo: Photo) -> Bool {
        switch sidebarSelection {
        case .folder, nil:
            return true
        case .rating(let rating):
            return photo.starRating == rating
        case .flying:
            return photo.isFlying
        case .picks:
            return photo.isPick
        case .species(let speciesID):
            return photoHasSpeciesID(photo, speciesID: speciesID)
        case .burstGroup(let groupID):
            return photo.burstGroupID == groupID
        case .singles(let speciesID):
            guard photo.burstGroupID == nil else { return false }
            return photoHasSpeciesID(photo, speciesID: speciesID)
        }
    }

    /// Multi-species-aware membership check. `nil` matches photos with an
    /// empty `assignedSpecies` list (Unidentified bucket).
    private func photoHasSpeciesID(_ photo: Photo, speciesID: String?) -> Bool {
        let assigned = photo.assignedSpecies
        if speciesID == nil { return assigned.isEmpty }
        return assigned.contains { $0.speciesID == speciesID }
    }

    /// Clear all photo data (when folder is removed).
    func clearPhotos() {
        allPhotos = []
        photos = []
        allPhotoIndex = [:]
        filteredPhotoIndex = [:]
        speciesEntries = []
        selection.clear()
        currentFolder = nil
        undoStack = []
    }

    /// Return the photo IDs that should receive a species edit originated
    /// from `id`. For a photo whose `burstGroupID` is non-nil, this is the
    /// full set of burst members (in `allPhotos` order); otherwise it is
    /// just `[id]`. Species edits fan out across the whole burst so the
    /// sidebar, keywords, and sidecars stay consistent across frames that
    /// depict the same bird(s).
    private func burstMemberIDs(for id: UUID) -> [UUID] {
        guard
            let idx = allPhotoIndex[id],
            let groupID = allPhotos[idx].burstGroupID
        else {
            return [id]
        }
        return allPhotos.filter { $0.burstGroupID == groupID }.map(\.id)
    }


    // MARK: - Test-only accessors

    #if DEBUG
    func allPhotosForTesting() -> [Photo] { allPhotos }
    func undoStackSizeForTesting() -> Int { undoStack.count }
    #endif

    // MARK: - Set-based mutation: pick / rate / reject

    /// Pick semantics across `ids`: if any photo in `ids` is unpicked, pick
    /// all of them; else unpick all. Explicit-only — does NOT fan out to
    /// burst members.
    func setPick(ids: Set<UUID>) {
        let targets = ids.compactMap { allPhotoIndex[$0].map { allPhotos[$0] } }
        guard !targets.isEmpty else { return }
        let anyUnpicked = targets.contains(where: { !$0.isPick })
        let newPick = anyUnpicked
        applyBatch(ids: targets.map(\.id)) { photo in
            photo.isPick = newPick
        } afterEach: { [weak self] photo in
            guard let self else { return }
            self.speciesEntries = SpeciesHierarchyBuilder.applyPickToggle(
                entries: self.speciesEntries, photo: photo, newIsPick: photo.isPick
            )
        }
    }

    func setRating(ids: Set<UUID>, rating: Int, manual: Bool = true) {
        applyBatch(ids: Array(ids)) { photo in
            photo.starRating = rating
            photo.isManualRating = manual
        }
    }

    func reject(ids: Set<UUID>) {
        applyBatch(ids: Array(ids), wasHidden: true) { photo in
            photo.starRating = 0
            photo.isManualRating = true
        } afterAll: { [weak self] _ in
            guard let self else { return }
            self.photos.removeAll { ids.contains($0.id) }
            self.rebuildFilteredPhotoIndex()
        }
    }

    // MARK: - Batch primitive

    /// Apply `mutate` to every id in `ids` against the DB and XMP, snapshot
    /// previous state into ONE `UndoAction`, update in-memory arrays, and
    /// optionally invoke per-photo and end-of-batch hooks. Photos missing
    /// from the DB are skipped.
    private func applyBatch(
        ids: [UUID],
        wasHidden: Bool = false,
        _ mutate: (inout Photo) -> Void,
        afterEach: ((Photo) -> Void)? = nil,
        afterAll: ((_ mutated: [Photo]) -> Void)? = nil
    ) {
        guard !ids.isEmpty else { return }
        do {
            let database = try db()
            var entries: [UndoAction.Entry] = []
            var mutated: [Photo] = []
            for id in ids {
                guard var photo = try database.fetchPhoto(id: id) else { continue }
                entries.append(UndoAction.Entry(
                    photoID: id,
                    previousRating: photo.starRating,
                    previousIsPick: photo.isPick,
                    previousIsManualRating: photo.isManualRating,
                    previousAssignedSpecies: photo.assignedSpecies,
                    wasHidden: wasHidden
                ))
                mutate(&photo)
                try database.save(&photo)
                _ = try? XMPWriter.write(photo: photo)
                if let idx = allPhotoIndex[id] { allPhotos[idx] = photo }
                if let fIdx = filteredPhotoIndex[id] { photos[fIdx] = photo }
                mutated.append(photo)
                afterEach?(photo)
            }
            if !entries.isEmpty {
                undoStack.append(UndoAction(entries: entries))
                if undoStack.count > Self.maxUndoDepth { undoStack.removeFirst() }
            }
            afterAll?(mutated)
        } catch {
            logger.error("applyBatch failed: \(error)")
        }
    }

    func deletePhoto(id: UUID) throws {
        let database = try db()
        guard let photo = try database.fetchPhoto(id: id) else { return }

        // Move to Trash
        let fileURL = URL(fileURLWithPath: photo.filePath)
        try FileManager.default.trashItem(at: fileURL, resultingItemURL: nil)

        // Remove from DB
        try database.delete(id: id)

        // Remove from memory
        allPhotos.removeAll { $0.id == id }
        photos.removeAll { $0.id == id }
        rebuildAllPhotoIndex()
        rebuildFilteredPhotoIndex()
        undoStack.removeAll { $0.entries.contains(where: { $0.photoID == id }) }

        logger.info("Deleted photo: \(photo.filename)")
    }

    // MARK: - Set-based mutation: species

    /// Inline rename of primary across `ids`. Each id's burst members are
    /// included (per-photo species edits fan out to the whole burst).
    /// Empty `commonName` is preserved as today.
    func correctSpecies(ids: Set<UUID>, commonName: String) {
        let trimmed = commonName.trimmingCharacters(in: .whitespaces)
        applySpeciesBatch(ids: ids) { photo in
            var list = photo.assignedSpecies
            if var first = list.first {
                first = SpeciesMatch(
                    scientificName: first.scientificName,
                    commonName: trimmed.isEmpty ? nil : trimmed,
                    confidence: first.confidence,
                    cnName: first.cnName,
                    pinyin: first.pinyin,
                    pinyinInitials: first.pinyinInitials,
                    thresholdUsed: first.thresholdUsed,
                    ebirdCode: first.ebirdCode
                )
                list[0] = first
                photo.assignedSpecies = list
            } else if !trimmed.isEmpty {
                photo.assignedSpecies = [SpeciesMatch(
                    scientificName: trimmed,
                    commonName: trimmed,
                    confidence: 0,
                    cnName: nil, pinyin: nil,
                    thresholdUsed: "manual", ebirdCode: nil
                )]
            }
        }
    }

    /// Set `species` as primary across `ids` (with burst fan-out). For each
    /// target photo: if `species` isn't already assigned, ADD it then
    /// promote to slot 0; else move existing entry to slot 0.
    func setPrimarySpecies(ids: Set<UUID>, species: SpeciesMatch) {
        applySpeciesBatch(ids: ids) { photo in
            var list = photo.assignedSpecies
            if let idx = list.firstIndex(where: { $0.speciesID == species.speciesID }) {
                list = SpeciesAssignmentEditor.makePrimary(at: idx, in: list)
            } else {
                list.insert(species, at: 0)
            }
            photo.assignedSpecies = list
        }
    }

    /// Add `species` to every target photo (with burst fan-out) that doesn't
    /// already have it. No-op for photos that already carry the species.
    func addSpecies(ids: Set<UUID>, species: SpeciesMatch) {
        applySpeciesBatch(ids: ids) { photo in
            if let updated = SpeciesAssignmentEditor.add(species, to: photo.assignedSpecies) {
                photo.assignedSpecies = updated
            }
        }
    }

    /// Remove `species` from every target photo (with burst fan-out) that
    /// has it.
    func removeSpecies(ids: Set<UUID>, species: SpeciesMatch) {
        applySpeciesBatch(ids: ids) { photo in
            if let idx = photo.assignedSpecies.firstIndex(where: { $0.speciesID == species.speciesID }) {
                photo.assignedSpecies = SpeciesAssignmentEditor.remove(at: idx, from: photo.assignedSpecies)
            }
        }
    }

    /// Common shape for every species mutation: expand burst membership,
    /// run the batch, rebuild the sidebar hierarchy once afterwards.
    private func applySpeciesBatch(ids: Set<UUID>, mutate: (inout Photo) -> Void) {
        let targets = expandBurstMembers(of: ids)
        applyBatch(ids: targets, mutate, afterAll: { [weak self] _ in
            self?.buildSpeciesHierarchy()
        })
    }

    /// Expand `ids` to include every burst member of every selected photo.
    /// Expand `ids` to include every burst member of every selected photo.
    /// Order: `ids` first (de-duped), then burst-member-only IDs in
    /// `allPhotos` order. The `applyBatch` body is order-independent for
    /// these methods, so this just keeps undo-entry order deterministic.
    private func expandBurstMembers(of ids: Set<UUID>) -> [UUID] {
        // Collect the burst groups touched by `ids` first so we can do one
        // O(N) pass over allPhotos instead of one filter per id.
        var groups: Set<UUID> = []
        for id in ids {
            if let idx = allPhotoIndex[id], let g = allPhotos[idx].burstGroupID {
                groups.insert(g)
            }
        }
        var result: [UUID] = []
        var seen: Set<UUID> = []
        for id in ids {
            if seen.insert(id).inserted { result.append(id) }
        }
        if groups.isEmpty { return result }
        for photo in allPhotos {
            guard let g = photo.burstGroupID, groups.contains(g) else { continue }
            if seen.insert(photo.id).inserted { result.append(photo.id) }
        }
        return result
    }

    func undoLastAction() {
        guard let action = undoStack.popLast() else { return }
        do {
            let database = try db()
            var lastID: UUID?
            var anySpeciesChanged = false
            for entry in action.entries {
                guard var photo = try database.fetchPhoto(id: entry.photoID) else { continue }
                let pickChanged = photo.isPick != entry.previousIsPick
                let speciesChanged = photo.assignedSpecies.map(\.speciesID) != entry.previousAssignedSpecies.map(\.speciesID)
                photo.starRating = entry.previousRating
                photo.isPick = entry.previousIsPick
                photo.isManualRating = entry.previousIsManualRating
                photo.assignedSpecies = entry.previousAssignedSpecies
                try database.save(&photo)
                _ = try? XMPWriter.write(photo: photo)

                if let idx = allPhotoIndex[entry.photoID] {
                    allPhotos[idx] = photo
                }
                if pickChanged {
                    speciesEntries = SpeciesHierarchyBuilder.applyPickToggle(
                        entries: speciesEntries,
                        photo: photo,
                        newIsPick: photo.isPick
                    )
                }
                if speciesChanged { anySpeciesChanged = true }

                if entry.wasHidden {
                    if filteredPhotoIndex[photo.id] == nil {
                        filteredPhotoIndex[photo.id] = photos.count
                        photos.append(photo)
                    }
                } else if let idx = filteredPhotoIndex[entry.photoID] {
                    photos[idx] = photo
                }
                lastID = photo.id
            }
            if anySpeciesChanged {
                buildSpeciesHierarchy()
            }
            if let id = lastID, photos.contains(where: { $0.id == id }) {
                selection.click(id, photos: photos)
            }
        } catch {
            logger.error("undoLastAction failed: \(error)")
        }
    }

    /// Filter photos by sidebar selection.
    func applyFilter() {
        switch sidebarSelection {
        case .folder:
            photos = allPhotos
        case .rating(let rating):
            photos = allPhotos.filter { $0.starRating == rating }
        case .flying:
            photos = allPhotos.filter { $0.isFlying }
        case .picks:
            photos = allPhotos.filter { $0.isPick }
        case .species(let speciesID):
            photos = allPhotos.filter { photoHasSpeciesID($0, speciesID: speciesID) }
        case .burstGroup(let groupID):
            photos = allPhotos.filter { $0.burstGroupID == groupID }
        case .singles(let speciesID):
            photos = allPhotos.filter { photo in
                photo.burstGroupID == nil && photoHasSpeciesID(photo, speciesID: speciesID)
            }
        case nil:
            photos = allPhotos
        }
        rebuildFilteredPhotoIndex()
        selection.reconcile(with: photos)
        if selection.activeID == nil, let first = photos.first {
            selection.click(first.id, photos: photos)
        }
    }
}
