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

private actor PhotoMutationWorker {
    private let logger = Logger(
        subsystem: "com.halfhacked.superpicky",
        category: "PhotoMutationWorker"
    )

    func apply(
        database: ReportDatabase,
        ids: [UUID],
        mutate: @Sendable (inout [Photo]) -> Void
    ) throws -> [PhotoMutationResult] {
        let results = try database.mutatePhotos(ids: ids, mutate)
        for result in results {
            do {
                _ = try XMPWriter.write(photo: result.updated)
            } catch {
                logger.error("XMP write failed for \(result.updated.filename): \(error)")
            }
        }
        return results
    }

    func delete(database: ReportDatabase, id: UUID) throws -> Photo? {
        guard let photo = try database.fetchPhoto(id: id) else { return nil }
        try FileManager.default.trashItem(
            at: URL(fileURLWithPath: photo.filePath),
            resultingItemURL: nil
        )
        try database.delete(id: id)
        return photo
    }
}

@Observable
final class AppState {
    private let logger = Logger(subsystem: "com.halfhacked.superpicky", category: "AppState")

    var sidebarSelection: SidebarSelection?
    /// Bumped whenever the displayed photo list changes due to a sidebar
    /// filter or folder switch. ContentView observes this to reset the
    /// active selection to the first photo in its current display sort.
    var filterToken: Int = 0
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

    struct UndoAction: Sendable {
        struct Entry: Sendable {
            let photoID: UUID
            let previousRating: Int
            let previousIsPick: Bool
            let previousIsManualRating: Bool
            let previousAssignedSpecies: [SpeciesMatch]
            let wasHidden: Bool
        }
        let entries: [Entry]
    }

    private struct MutationContext: Sendable {
        let folder: URL
        let database: ReportDatabase
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
    @ObservationIgnored private let mutationWorker = PhotoMutationWorker()
    @ObservationIgnored private var pendingMutationTask: Task<Void, Never>?

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

    @MainActor
    private func mutationContext() -> MutationContext? {
        guard let folder = currentFolder else {
            logger.error("Photo mutation requested without a current folder")
            return nil
        }
        do {
            return MutationContext(folder: folder, database: try db())
        } catch {
            logger.error("Failed to open report database for mutation: \(error)")
            return nil
        }
    }

    @MainActor
    private func completedMutationTask() -> Task<Void, Never> {
        Task { @MainActor in }
    }

    /// Chain complete mutations, including their main-actor state commits, so
    /// rapid edits preserve click order while all database and sidecar I/O runs
    /// on `PhotoMutationWorker` instead of the UI executor.
    @MainActor
    private func enqueueMutation(
        _ operation: @escaping @MainActor (AppState) async -> Void
    ) -> Task<Void, Never> {
        let previous = pendingMutationTask
        let task = Task { @MainActor [weak self] in
            await previous?.value
            guard let self, !Task.isCancelled else { return }
            await operation(self)
        }
        pendingMutationTask = task
        return task
    }

    /// Load photos from the database for the selected folder.
    /// Preserves current filter and selection when possible.
    /// Pass `skipHierarchy: true` during incremental processing to avoid O(n²) rebuilds.
    /// Pass `deferSelection: true` from a user-initiated sidebar click so the
    /// view layer can pick the displayed-first photo even when re-clicking the
    /// already-loaded folder (where `isFolderSwitch` would otherwise be `false`).
    func loadPhotos(for folder: URL, skipHierarchy: Bool = false, deferSelection: Bool = false) {
        let isFolderSwitch = (currentFolder != folder)
        // Sidebar re-click on the already-loaded folder: the in-memory
        // photo set, indices, species hierarchy, undo stack, and DB cache
        // are all still valid. Skip the full reload and just nudge the
        // view layer to re-select display-first via filterToken.
        if !isFolderSwitch && deferSelection {
            applyFilter(autoSelectFirst: false)
            return
        }
        let shouldDeferSelection = isFolderSwitch || deferSelection
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

            // Re-apply current filter instead of resetting to all.
            // Folder switch (or any user-driven sidebar click) defers
            // selection to the view layer so the first photo picked
            // respects the user's current sort order.
            applyFilter(autoSelectFirst: !shouldDeferSelection)

            if isFolderSwitch {
                let paths = allPhotos.map(\.filePath)
                let prefillPhotos = allPhotos
                Task { @MainActor in
                    PreviewSweepCoordinator.shared.start(folder: folder, paths: paths)
                    PrefetchCoordinator.shared.reset()
                    NavigationStateMonitor.shared.reset()
                    if !prefillPhotos.isEmpty {
                        PrefetchCoordinator.shared.prefill(photos: prefillPhotos, around: 0)
                    }
                }
            }
        } catch {
            logger.error("loadPhotos failed: \(error)")
            allPhotos = []
            allPhotoIndex = [:]
            speciesEntries = []
            applyFilter(autoSelectFirst: !shouldDeferSelection)
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
    @MainActor
    @discardableResult
    func setPick(ids: Set<UUID>) -> Task<Void, Never> {
        guard !ids.isEmpty, let context = mutationContext() else {
            return completedMutationTask()
        }
        return enqueueMutation { state in
            await state.applyBatch(context: context, ids: Array(ids)) { photos in
                let newPick = photos.contains(where: { !$0.isPick })
                for index in photos.indices {
                    photos[index].isPick = newPick
                }
            } afterEach: { [weak state] photo in
                guard let state else { return }
                state.speciesEntries = SpeciesHierarchyBuilder.applyPickToggle(
                    entries: state.speciesEntries,
                    photo: photo,
                    newIsPick: photo.isPick
                )
            }
        }
    }

    @MainActor
    @discardableResult
    func setRating(ids: Set<UUID>, rating: Int, manual: Bool = true) -> Task<Void, Never> {
        guard !ids.isEmpty, let context = mutationContext() else {
            return completedMutationTask()
        }
        return enqueueMutation { state in
            await state.applyBatch(context: context, ids: Array(ids)) { photos in
                for index in photos.indices {
                    photos[index].starRating = rating
                    photos[index].isManualRating = manual
                }
            }
        }
    }

    @MainActor
    @discardableResult
    func reject(ids: Set<UUID>) -> Task<Void, Never> {
        guard !ids.isEmpty, let context = mutationContext() else {
            return completedMutationTask()
        }
        return enqueueMutation { state in
            await state.applyBatch(
                context: context,
                ids: Array(ids),
                wasHidden: true
            ) { photos in
                for index in photos.indices {
                    photos[index].starRating = 0
                    photos[index].isManualRating = true
                }
            } afterAll: { [weak state] _ in
                guard let state else { return }
                state.photos.removeAll { ids.contains($0.id) }
                state.rebuildFilteredPhotoIndex()
            }
        }
    }

    // MARK: - Batch primitive

    /// Persist a batch away from the main actor, then commit its resulting
    /// photos and one undo action to observable state.
    @MainActor
    private func applyBatch(
        context: MutationContext,
        ids: [UUID],
        wasHidden: Bool = false,
        _ mutate: @escaping @Sendable (inout [Photo]) -> Void,
        afterEach: ((Photo) -> Void)? = nil,
        afterAll: ((_ mutated: [Photo]) -> Void)? = nil
    ) async {
        guard !ids.isEmpty else { return }
        do {
            let results = try await mutationWorker.apply(
                database: context.database,
                ids: ids,
                mutate: mutate
            )
            guard currentFolder == context.folder else { return }

            var entries: [UndoAction.Entry] = []
            var mutated: [Photo] = []
            entries.reserveCapacity(results.count)
            mutated.reserveCapacity(results.count)
            for result in results {
                let previous = result.previous
                let photo = result.updated
                entries.append(UndoAction.Entry(
                    photoID: previous.id,
                    previousRating: previous.starRating,
                    previousIsPick: previous.isPick,
                    previousIsManualRating: previous.isManualRating,
                    previousAssignedSpecies: previous.assignedSpecies,
                    wasHidden: wasHidden
                ))
                if let idx = allPhotoIndex[photo.id] { allPhotos[idx] = photo }
                if let fIdx = filteredPhotoIndex[photo.id] { photos[fIdx] = photo }
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

    @MainActor
    @discardableResult
    func deletePhoto(id: UUID) -> Task<Void, Never> {
        guard let context = mutationContext() else {
            return completedMutationTask()
        }
        return enqueueMutation { state in
            do {
                guard let photo = try await state.mutationWorker.delete(
                    database: context.database,
                    id: id
                ) else {
                    return
                }
                guard state.currentFolder == context.folder else { return }

                state.allPhotos.removeAll { $0.id == id }
                state.photos.removeAll { $0.id == id }
                state.rebuildAllPhotoIndex()
                state.rebuildFilteredPhotoIndex()
                state.undoStack.removeAll {
                    $0.entries.contains(where: { $0.photoID == id })
                }
                state.logger.info("Deleted photo: \(photo.filename)")
            } catch {
                state.logger.error("deletePhoto failed: \(error)")
            }
        }
    }

    // MARK: - Set-based mutation: species

    /// Inline rename of primary across `ids`. Each id's burst members are
    /// included (per-photo species edits fan out to the whole burst).
    /// Empty `commonName` is preserved as today.
    @MainActor
    @discardableResult
    func correctSpecies(ids: Set<UUID>, commonName: String) -> Task<Void, Never> {
        let trimmed = commonName.trimmingCharacters(in: .whitespaces)
        return applySpeciesBatch(ids: ids) { photos in
            for index in photos.indices {
                var list = photos[index].assignedSpecies
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
                    photos[index].assignedSpecies = list
                } else if !trimmed.isEmpty {
                    photos[index].assignedSpecies = [SpeciesMatch(
                        scientificName: trimmed,
                        commonName: trimmed,
                        confidence: 0,
                        cnName: nil, pinyin: nil,
                        thresholdUsed: "manual", ebirdCode: nil
                    )]
                }
            }
        }
    }

    /// Set `species` as primary across `ids` (with burst fan-out). For each
    /// target photo: if `species` isn't already assigned, ADD it then
    /// promote to slot 0; else move existing entry to slot 0.
    @MainActor
    @discardableResult
    func setPrimarySpecies(ids: Set<UUID>, species: SpeciesMatch) -> Task<Void, Never> {
        applySpeciesBatch(ids: ids) { photos in
            for index in photos.indices {
                var list = photos[index].assignedSpecies
                if let matchIndex = list.firstIndex(where: {
                    $0.speciesID == species.speciesID
                }) {
                    list = SpeciesAssignmentEditor.makePrimary(at: matchIndex, in: list)
                } else {
                    list.insert(species, at: 0)
                }
                photos[index].assignedSpecies = list
            }
        }
    }

    /// Add `species` to every target photo (with burst fan-out) that doesn't
    /// already have it. No-op for photos that already carry the species.
    @MainActor
    @discardableResult
    func addSpecies(ids: Set<UUID>, species: SpeciesMatch) -> Task<Void, Never> {
        applySpeciesBatch(ids: ids) { photos in
            for index in photos.indices {
                if let updated = SpeciesAssignmentEditor.add(
                    species,
                    to: photos[index].assignedSpecies
                ) {
                    photos[index].assignedSpecies = updated
                }
            }
        }
    }

    /// Remove `species` from every target photo (with burst fan-out) that
    /// has it.
    @MainActor
    @discardableResult
    func removeSpecies(ids: Set<UUID>, species: SpeciesMatch) -> Task<Void, Never> {
        applySpeciesBatch(ids: ids) { photos in
            for index in photos.indices {
                let assigned = photos[index].assignedSpecies
                if let matchIndex = assigned.firstIndex(where: {
                    $0.speciesID == species.speciesID
                }) {
                    photos[index].assignedSpecies = SpeciesAssignmentEditor.remove(
                        at: matchIndex,
                        from: assigned
                    )
                }
            }
        }
    }

    /// Common shape for every species mutation: expand burst membership,
    /// run the batch, rebuild the sidebar hierarchy once afterwards.
    @MainActor
    private func applySpeciesBatch(
        ids: Set<UUID>,
        mutate: @escaping @Sendable (inout [Photo]) -> Void
    ) -> Task<Void, Never> {
        let targets = expandBurstMembers(of: ids)
        guard !targets.isEmpty, let context = mutationContext() else {
            return completedMutationTask()
        }
        return enqueueMutation { state in
            await state.applyBatch(
                context: context,
                ids: targets,
                mutate,
                afterAll: { [weak state] _ in
                    state?.buildSpeciesHierarchy()
                }
            )
        }
    }

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

    @MainActor
    @discardableResult
    func undoLastAction() -> Task<Void, Never> {
        guard let context = mutationContext() else {
            return completedMutationTask()
        }
        return enqueueMutation { state in
            await state.performUndo(context: context)
        }
    }

    @MainActor
    private func performUndo(context: MutationContext) async {
        guard currentFolder == context.folder, let action = undoStack.popLast() else {
            return
        }
        let entriesByID = Dictionary(
            uniqueKeysWithValues: action.entries.map { ($0.photoID, $0) }
        )
        do {
            let results = try await mutationWorker.apply(
                database: context.database,
                ids: action.entries.map(\.photoID)
            ) { photos in
                for index in photos.indices {
                    guard let entry = entriesByID[photos[index].id] else { continue }
                    photos[index].starRating = entry.previousRating
                    photos[index].isPick = entry.previousIsPick
                    photos[index].isManualRating = entry.previousIsManualRating
                    photos[index].assignedSpecies = entry.previousAssignedSpecies
                }
            }
            guard currentFolder == context.folder else { return }

            var lastID: UUID?
            var anySpeciesChanged = false
            for result in results {
                let photo = result.updated
                guard let entry = entriesByID[photo.id] else { continue }
                let pickChanged = result.previous.isPick != photo.isPick
                let speciesChanged = result.previous.assignedSpecies.map(\.speciesID)
                    != photo.assignedSpecies.map(\.speciesID)

                if let idx = allPhotoIndex[photo.id] {
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
                } else if let idx = filteredPhotoIndex[photo.id] {
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
            if currentFolder == context.folder {
                undoStack.append(action)
            }
            logger.error("undoLastAction failed: \(error)")
        }
    }

    /// Filter photos by sidebar selection.
    ///
    /// When `autoSelectFirst` is `true` (the default), the legacy behavior
    /// of selecting `photos.first` whenever no selection survives reconcile
    /// stays. When `false`, selection is left as-is and `filterToken` is
    /// bumped so the view layer can pick the displayed-first photo using
    /// its own sort order.
    func applyFilter(autoSelectFirst: Bool = true) {
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
        if autoSelectFirst {
            if selection.activeID == nil, let first = photos.first {
                selection.click(first.id, photos: photos)
            }
        } else {
            filterToken += 1
        }
    }
}
