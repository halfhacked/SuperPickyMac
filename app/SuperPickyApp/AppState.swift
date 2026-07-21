import SwiftUI
import AppKit
import os

enum SidebarSelection: Hashable {
    case folder(URL)
    case rating(Int)
    case rejected
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

private struct PendingSpeciesEditRender {
    let operation: String
    let targetPhotoCount: Int
    let startedAt: TimeInterval
    let signpostID: OSSignpostID
}

/// Result of a deferred species overlay run against SQLite.
private struct SpeciesPersistResult: Sendable {
    let written: [Photo]
    let databaseMilliseconds: Double
}

/// Summary of one XMP write-behind drain, reported back to `AppState` so it can
/// surface persistent failures and log deferred sidecar latency separately from
/// the synchronous edit.
private struct XMPFlushSummary: Sendable {
    let writeCount: Int
    let failureCount: Int
    let slowestMilliseconds: Double
    let totalMilliseconds: Double
    let failedPhotos: [Photo]
    /// Sidecar paths written successfully in this drain. Used by `AppState` to
    /// clear durable XMP failure state for exactly the paths that recovered.
    let succeededSidecarPaths: [String]
    /// Sidecar paths that failed to write in this drain (still pending).
    let failedSidecarPaths: [String]
}

private actor PhotoMutationWorker {
    private let logger = Logger(
        subsystem: "com.halfhacked.superpicky",
        category: "PhotoMutationWorker"
    )

    /// Full read-modify-write used by pick / rate / reject and field-undo.
    /// XMP is written synchronously here to preserve existing behavior for
    /// those non-species mutations.
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

    /// Deferred species overlay: applies captured desired species onto fresh
    /// rows. XMP is NOT written here — the returned rows are handed to the
    /// debounced write-behind queue by the caller.
    func persistSpecies(
        database: ReportDatabase,
        snapshots: [SpeciesSnapshot]
    ) throws -> SpeciesPersistResult {
        let startedAt = SpeciesEditProfiler.now()
        let written = try database.overlaySpecies(snapshots)
        return SpeciesPersistResult(
            written: written,
            databaseMilliseconds: SpeciesEditProfiler.elapsedMilliseconds(since: startedAt)
        )
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

/// Debounced, path-keyed XMP write-behind queue.
///
/// Species edits are optimistic: SQLite is overlaid on the serialized mutation
/// chain, but the durable XMP sidecar is written *behind* the UI. Each sidecar
/// path retains only the latest `Photo`, so rapid edits coalesce into a single
/// write. Failed writes stay pending (path-keyed, so a newer edit supersedes
/// them). `flush()` drains deterministically for tests and termination — no
/// test ever waits on the debounce timer.
private actor XMPWriteBehindQueue {
    private var pending: [String: Photo] = [:]
    private var debounceTask: Task<Void, Never>?
    private let debounceNanoseconds: UInt64
    private let onFlush: @Sendable (XMPFlushSummary) -> Void

    init(
        debounceMilliseconds: Double,
        onFlush: @escaping @Sendable (XMPFlushSummary) -> Void
    ) {
        self.debounceNanoseconds = UInt64(max(0, debounceMilliseconds) * 1_000_000)
        self.onFlush = onFlush
    }

    func enqueue(_ photos: [Photo]) {
        guard !photos.isEmpty else { return }
        for photo in photos {
            pending[XMPWriter.sidecarURL(for: photo).path] = photo
        }
        scheduleDebounce()
    }

    /// Drop any pending write for a sidecar path — used when the underlying
    /// photo is deleted so we don't resurrect an orphan sidecar.
    func evict(sidecarPath: String) {
        pending.removeValue(forKey: sidecarPath)
    }

    func pendingCount() -> Int { pending.count }

    @discardableResult
    func flush() -> XMPFlushSummary {
        debounceTask?.cancel()
        debounceTask = nil
        return drain()
    }

    private func scheduleDebounce() {
        debounceTask?.cancel()
        debounceTask = Task { [weak self, debounceNanoseconds] in
            try? await Task.sleep(nanoseconds: debounceNanoseconds)
            guard let self, !Task.isCancelled else { return }
            let summary = await self.drain()
            if summary.writeCount + summary.failureCount > 0 {
                self.onFlush(summary)
            }
        }
    }

    /// Synchronous within the actor: `XMPWriter.write` never suspends, so no
    /// `enqueue` can interleave with the write loop. Failures are re-queued.
    @discardableResult
    private func drain() -> XMPFlushSummary {
        guard !pending.isEmpty else {
            return XMPFlushSummary(
                writeCount: 0, failureCount: 0,
                slowestMilliseconds: 0, totalMilliseconds: 0, failedPhotos: [],
                succeededSidecarPaths: [], failedSidecarPaths: []
            )
        }
        let started = SpeciesEditProfiler.now()
        let batch = pending
        pending = [:]
        var writeCount = 0
        var failedPhotos: [Photo] = []
        var succeededSidecarPaths: [String] = []
        var failedSidecarPaths: [String] = []
        var slowest = 0.0
        for (path, photo) in batch {
            let writeStart = SpeciesEditProfiler.now()
            do {
                _ = try XMPWriter.write(photo: photo)
                writeCount += 1
                succeededSidecarPaths.append(path)
            } catch {
                // Keep the failed write pending unless a newer edit already
                // superseded this path during the (non-suspending) loop.
                if pending[path] == nil { pending[path] = photo }
                failedPhotos.append(photo)
                failedSidecarPaths.append(path)
            }
            slowest = max(slowest, SpeciesEditProfiler.elapsedMilliseconds(since: writeStart))
        }
        return XMPFlushSummary(
            writeCount: writeCount,
            failureCount: failedPhotos.count,
            slowestMilliseconds: slowest,
            totalMilliseconds: SpeciesEditProfiler.elapsedMilliseconds(since: started),
            failedPhotos: failedPhotos,
            succeededSidecarPaths: succeededSidecarPaths,
            failedSidecarPaths: failedSidecarPaths
        )
    }
}

/// Coordinates a bounded, single-reply drain of every registered `AppState`
/// before the app terminates, and an opportunistic flush when the app resigns
/// active. Lives here (rather than a new file) to avoid pbxproj churn.
@MainActor
final class FlushCoordinator {
    static let shared = FlushCoordinator()

    private var handlers: [(id: ObjectIdentifier, flush: () async -> Void)] = []
    private var isTerminationReplyPending = false

    /// Register (or replace) a flush handler keyed by owner identity so repeat
    /// `onAppear` calls don't accumulate duplicates.
    func register(owner: AnyObject, flush: @escaping () async -> Void) {
        let id = ObjectIdentifier(owner)
        handlers.removeAll { $0.id == id }
        handlers.append((id, flush))
    }

    func flushAll() async {
        for handler in handlers {
            await handler.flush()
        }
    }

    /// AppKit `applicationShouldTerminate` bridge. Returns `.terminateLater`
    /// once and replies exactly once after every handler drains.
    func handleTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !isTerminationReplyPending else { return .terminateLater }
        isTerminationReplyPending = true
        Task { @MainActor in
            await flushAll()
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
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
        for photo in allPhotos {
            counts[photo.starRating, default: 0] += 1
        }
        return counts
    }
    var rejectedCount: Int { allPhotos.lazy.filter(\.isRejected).count }
    var flyingCount: Int { allPhotos.lazy.filter(\.isFlying).count }
    var picksCount: Int { allPhotos.lazy.filter(\.isPick).count }

    struct UndoAction: Sendable {
        /// Distinguishes species edits (optimistic: observable state is applied
        /// synchronously and only species is persisted) from field mutations
        /// (pick / rate / reject — persist-first, full-row restore on undo).
        enum Kind: Sendable {
            case fields
            case species
        }
        struct Entry: Sendable {
            let photoID: UUID
            let previousRating: Int
            let previousIsPick: Bool
            let previousIsManualRating: Bool
            let previousIsRejected: Bool
            let previousAssignedSpecies: [SpeciesMatch]
        }
        var kind: Kind = .fields
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
    @ObservationIgnored private var lastSpeciesEditProfile: SpeciesEditProfile?
    @ObservationIgnored private var pendingSpeciesEditRender: PendingSpeciesEditRender?
    private(set) var speciesEditRenderToken = 0
    private(set) var speciesXMPFlushToken = 0

    // MARK: Optimistic species-edit persistence

    /// Monotonic generation stamped on every optimistic species edit (and undo).
    /// Used to supersede older failed snapshots and stale optimistic overrides.
    @ObservationIgnored private var speciesEditGeneration = 0

    /// Desired species applied optimistically but not yet confirmed persisted.
    /// Keyed by photo id; keeps `appendProcessedPhoto` from clobbering a user
    /// edit with a pipeline row while persistence is still in flight.
    @ObservationIgnored private var pendingOptimisticSpecies: [UUID: (generation: Int, species: [SpeciesMatch])] = [:]

    /// Latest failed SQLite species snapshot per photo, retained with its
    /// original folder/database so retry works even after a folder switch.
    @ObservationIgnored private var failedSpeciesEdits: [UUID: FailedSpeciesEdit] = [:]

    /// Durable set of XMP sidecar paths whose write-behind write failed and is
    /// still pending in the queue. Keeps the retry banner visible independently
    /// of SQLite failure state, so an unrelated success/delete can't clear it
    /// while a failed sidecar remains. A path is removed only when it later
    /// writes successfully or its photo is deleted (queue eviction).
    @ObservationIgnored private var failedXMPSidecars: Set<String> = []

    private struct FailedSpeciesEdit {
        let generation: Int
        let folder: URL
        let database: ReportDatabase
        let snapshot: SpeciesSnapshot
    }

    /// Observable, user-facing persistence failure surface (drives the retry
    /// banner in the species edit panel). `nil` when everything is saved.
    private(set) var speciesPersistenceFailureMessage: String?
    var hasSpeciesPersistenceFailure: Bool { speciesPersistenceFailureMessage != nil }

    @ObservationIgnored private let xmpDebounceMilliseconds: Double
    @ObservationIgnored private var _xmpQueue: XMPWriteBehindQueue?
    private var xmpQueue: XMPWriteBehindQueue {
        if let queue = _xmpQueue { return queue }
        let queue = XMPWriteBehindQueue(
            debounceMilliseconds: xmpDebounceMilliseconds
        ) { [weak self] summary in
            Task { @MainActor in self?.handleXMPFlush(summary) }
        }
        _xmpQueue = queue
        return queue
    }

    /// - Parameter xmpDebounceMilliseconds: write-behind debounce window. Capped
    ///   at 150 ms in production; tests never wait on it (they call
    ///   `flushPendingPersistence()`), so its value is irrelevant to them.
    init(xmpDebounceMilliseconds: Double = 150) {
        self.xmpDebounceMilliseconds = min(max(0, xmpDebounceMilliseconds), 150)
    }

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
    func loadPhotos(
        for folder: URL,
        skipHierarchy: Bool = false,
        deferSelection: Bool = false,
        startPreviewSweep: Bool = true
    ) {
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

            if startPreviewSweep || isFolderSwitch {
                let prefillPhotos = allPhotos
                Task { @MainActor in
                    if startPreviewSweep {
                        let paths = prefillPhotos.map(\.filePath)
                        PreviewSweepCoordinator.shared.start(folder: folder, paths: paths)
                    }
                    if isFolderSwitch {
                        PrefetchCoordinator.shared.reset()
                        NavigationStateMonitor.shared.reset()
                        if !prefillPhotos.isEmpty {
                            PrefetchCoordinator.shared.prefill(photos: prefillPhotos, around: 0)
                        }
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
        // Preserve an in-flight optimistic species edit: the pipeline row would
        // otherwise clobber the user's just-made change with model output.
        // Persistence still merges species onto a freshly-fetched DB row, so the
        // durable copy stays correct regardless of what we show here.
        var photo = photo
        if let optimistic = pendingOptimisticSpecies[photo.id] {
            photo.assignedSpecies = optimistic.species
        }
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
        case .rejected:
            return photo.isRejected
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
    func lastSpeciesEditProfileForTesting() -> SpeciesEditProfile? {
        lastSpeciesEditProfile
    }
    func pendingXMPWriteCountForTesting() async -> Int {
        await xmpQueue.pendingCount()
    }
    func failedSpeciesEditCountForTesting() -> Int { failedSpeciesEdits.count }
    func failedXMPSidecarCountForTesting() -> Int { failedXMPSidecars.count }
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
            await state.applyBatch(context: context, ids: Array(ids)) { photos in
                for index in photos.indices {
                    photos[index].isRejected = true
                }
            }
        }
    }

    // MARK: - Batch primitive (pick / rate / reject: persist-first)

    /// Persist a batch away from the main actor, then commit its resulting
    /// photos and one undo action to observable state. Used only by the
    /// non-species field mutations, which keep their existing persist-first,
    /// synchronous-XMP behavior. Species edits use the optimistic path below.
    @MainActor
    private func applyBatch(
        context: MutationContext,
        ids: [UUID],
        _ mutate: @escaping @Sendable (inout [Photo]) -> Void,
        afterEach: ((Photo) -> Void)? = nil
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
            entries.reserveCapacity(results.count)
            for result in results {
                let previous = result.previous
                let photo = result.updated
                entries.append(UndoAction.Entry(
                    photoID: previous.id,
                    previousRating: previous.starRating,
                    previousIsPick: previous.isPick,
                    previousIsManualRating: previous.isManualRating,
                    previousIsRejected: previous.isRejected,
                    previousAssignedSpecies: previous.assignedSpecies
                ))
                if let idx = allPhotoIndex[photo.id] { allPhotos[idx] = photo }
                afterEach?(photo)
            }
            if !entries.isEmpty {
                undoStack.append(UndoAction(kind: .fields, entries: entries))
                if undoStack.count > Self.maxUndoDepth { undoStack.removeFirst() }
            }
            applyFilter()
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
                // Evict any pending write-behind XMP for this sidecar so a
                // deferred flush can't recreate an orphan sidecar next to the
                // now-trashed original. Drop any failed/optimistic state too.
                let sidecarPath = XMPWriter.sidecarURL(for: photo).path
                await state.xmpQueue.evict(sidecarPath: sidecarPath)
                state.pendingOptimisticSpecies.removeValue(forKey: id)
                state.failedSpeciesEdits.removeValue(forKey: id)
                state.failedXMPSidecars.remove(sidecarPath)
                guard state.currentFolder == context.folder else {
                    state.refreshSpeciesFailureMessage()
                    return
                }

                state.allPhotos.removeAll { $0.id == id }
                state.photos.removeAll { $0.id == id }
                state.rebuildAllPhotoIndex()
                state.rebuildFilteredPhotoIndex()
                state.undoStack.removeAll {
                    $0.entries.contains(where: { $0.photoID == id })
                }
                state.refreshSpeciesFailureMessage()
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
        return applySpeciesBatch(ids: ids, operation: "rename") { photos in
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
        applySpeciesBatch(ids: ids, operation: "set-primary") { photos in
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
        applySpeciesBatch(ids: ids, operation: "add") { photos in
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
        applySpeciesBatch(ids: ids, operation: "remove") { photos in
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

    /// Common shape for every species mutation. Applies the edit to observable
    /// state *synchronously* (optimistic), registers one undo action for the
    /// genuinely-changed rows, updates the sidebar hierarchy, then enqueues the
    /// deferred persistence (serialized SQLite overlay + write-behind XMP). The
    /// returned task resolves once SQLite has committed and XMP has been queued.
    @MainActor
    private func applySpeciesBatch(
        ids: Set<UUID>,
        operation: String,
        mutate: @escaping @Sendable (inout [Photo]) -> Void
    ) -> Task<Void, Never> {
        let totalStartedAt = SpeciesEditProfiler.now()
        let traceID = SpeciesEditProfiler.signposter.makeSignpostID()
        let totalInterval = SpeciesEditProfiler.signposter.beginInterval(
            "Species Edit",
            id: traceID,
            "operation: \(operation, privacy: .public), requested: \(ids.count)"
        )

        let expansionStartedAt = SpeciesEditProfiler.now()
        let targets = expandBurstMembers(of: ids)
        let expansionMilliseconds = SpeciesEditProfiler.elapsedMilliseconds(since: expansionStartedAt)
        guard !targets.isEmpty, let context = mutationContext() else {
            SpeciesEditProfiler.signposter.endInterval("Species Edit", totalInterval, "applied: false")
            return completedMutationTask()
        }

        // --- Immediate optimistic apply (synchronous, before returning) ---
        let stateStartedAt = SpeciesEditProfiler.now()
        var working: [Photo] = []
        working.reserveCapacity(targets.count)
        for id in targets {
            guard let idx = allPhotoIndex[id] else { continue }
            working.append(allPhotos[idx])
        }
        let previousPhotos = working
        let previousSpecies = working.map { $0.assignedSpecies }
        mutate(&working)

        var undoEntries: [UndoAction.Entry] = []
        var snapshots: [SpeciesSnapshot] = []
        let generation = nextSpeciesEditGeneration()
        for (offset, photo) in working.enumerated() {
            let before = previousSpecies[offset]
            let after = photo.assignedSpecies
            guard before != after else { continue }
            if let idx = allPhotoIndex[photo.id] { allPhotos[idx] = photo }
            if let fIdx = filteredPhotoIndex[photo.id] { photos[fIdx] = photo }
            undoEntries.append(UndoAction.Entry(
                photoID: photo.id,
                previousRating: photo.starRating,
                previousIsPick: photo.isPick,
                previousIsManualRating: photo.isManualRating,
                previousIsRejected: photo.isRejected,
                previousAssignedSpecies: before
            ))
            snapshots.append(SpeciesSnapshot(id: photo.id, species: after))
            pendingOptimisticSpecies[photo.id] = (generation, after)
        }

        let stateApplyMilliseconds = SpeciesEditProfiler.elapsedMilliseconds(since: stateStartedAt)

        guard !undoEntries.isEmpty else {
            // Logical no-op: no undo entry, no DB update, no XMP write.
            lastSpeciesEditProfile = SpeciesEditProfile(
                operation: operation,
                requestedPhotoCount: ids.count,
                targetPhotoCount: targets.count,
                changedPhotoCount: 0,
                expansionMilliseconds: expansionMilliseconds,
                stateApplyMilliseconds: stateApplyMilliseconds,
                hierarchyMilliseconds: 0,
                immediateMilliseconds: SpeciesEditProfiler.elapsedMilliseconds(since: totalStartedAt)
            )
            SpeciesEditProfiler.signposter.endInterval("Species Edit", totalInterval, "applied: false")
            return completedMutationTask()
        }

        undoStack.append(UndoAction(kind: .species, entries: undoEntries))
        if undoStack.count > Self.maxUndoDepth { undoStack.removeFirst() }

        let hierarchyStartedAt = SpeciesEditProfiler.now()
        speciesEntries = SpeciesHierarchyBuilder.applySpeciesChanges(
            entries: speciesEntries,
            changes: zip(previousPhotos, working).map {
                SpeciesHierarchyChange(previous: $0.0, updated: $0.1)
            },
            sortOrder: speciesSortOrder,
            displayName: speciesDisplayName,
            locale: speciesSortLocale
        )
        let hierarchyMilliseconds = SpeciesEditProfiler.elapsedMilliseconds(since: hierarchyStartedAt)

        let profile = SpeciesEditProfile(
            operation: operation,
            requestedPhotoCount: ids.count,
            targetPhotoCount: targets.count,
            changedPhotoCount: snapshots.count,
            expansionMilliseconds: expansionMilliseconds,
            stateApplyMilliseconds: stateApplyMilliseconds,
            hierarchyMilliseconds: hierarchyMilliseconds,
            immediateMilliseconds: SpeciesEditProfiler.elapsedMilliseconds(since: totalStartedAt)
        )
        lastSpeciesEditProfile = profile

        pendingSpeciesEditRender = PendingSpeciesEditRender(
            operation: operation,
            targetPhotoCount: targets.count,
            startedAt: totalStartedAt,
            signpostID: traceID
        )
        speciesEditRenderToken &+= 1
        SpeciesEditProfiler.signposter.endInterval(
            "Species Edit",
            totalInterval,
            "operation: \(operation, privacy: .public), immediate_ms: \(profile.immediateMilliseconds)"
        )

        // --- Deferred persistence, serialized on the mutation chain ---
        return enqueueMutation { state in
            await state.persistSpeciesSnapshots(
                context: context,
                snapshots: snapshots,
                generation: generation,
                operation: operation,
                profile: profile
            )
        }
    }

    private func nextSpeciesEditGeneration() -> Int {
        speciesEditGeneration &+= 1
        return speciesEditGeneration
    }

    /// Overlay captured desired species onto fresh DB rows (off the main actor),
    /// then hand the written rows to the write-behind XMP queue. Never publishes
    /// DB results back into observable state — the UI already holds them.
    @MainActor
    private func persistSpeciesSnapshots(
        context: MutationContext,
        snapshots: [SpeciesSnapshot],
        generation: Int,
        operation: String,
        profile: SpeciesEditProfile?
    ) async {
        guard !snapshots.isEmpty else { return }
        do {
            let result = try await mutationWorker.persistSpecies(
                database: context.database,
                snapshots: snapshots
            )
            await xmpQueue.enqueue(result.written)
            clearOptimisticState(for: snapshots, upTo: generation)
            if var profile {
                profile.persistedPhotoCount = result.written.count
                profile.databaseMilliseconds = result.databaseMilliseconds
                profile.queuedXMPWriteCount = result.written.count
                lastSpeciesEditProfile = profile
                SpeciesEditProfiler.logger.info("\(profile.summary, privacy: .public)")
            }
            refreshSpeciesFailureMessage()
        } catch {
            recordSpeciesFailures(context: context, snapshots: snapshots, generation: generation)
            if var profile {
                profile.persistenceFailed = true
                lastSpeciesEditProfile = profile
            }
            logger.error("species persistence failed (\(operation)): \(error)")
        }
    }

    /// Drop optimistic overrides that this persisted generation satisfies. A
    /// newer edit (higher generation) is left in place so its own persistence
    /// completes it.
    private func clearOptimisticState(for snapshots: [SpeciesSnapshot], upTo generation: Int) {
        for snapshot in snapshots {
            if let entry = pendingOptimisticSpecies[snapshot.id], entry.generation <= generation {
                pendingOptimisticSpecies.removeValue(forKey: snapshot.id)
            }
            if let failed = failedSpeciesEdits[snapshot.id], failed.generation <= generation {
                failedSpeciesEdits.removeValue(forKey: snapshot.id)
            }
        }
    }

    private func recordSpeciesFailures(
        context: MutationContext,
        snapshots: [SpeciesSnapshot],
        generation: Int
    ) {
        for snapshot in snapshots {
            // Only supersede an older failure — a newer edit's failure wins.
            if let existing = failedSpeciesEdits[snapshot.id], existing.generation > generation {
                continue
            }
            failedSpeciesEdits[snapshot.id] = FailedSpeciesEdit(
                generation: generation,
                folder: context.folder,
                database: context.database,
                snapshot: snapshot
            )
        }
        speciesPersistenceFailureMessage = Self.persistenceFailureMessage
    }

    @MainActor
    private func handleXMPFlush(_ summary: XMPFlushSummary) {
        if summary.writeCount + summary.failureCount > 0 {
            SpeciesEditProfiler.logger.info(
                "species_xmp_flush writes=\(summary.writeCount) failures=\(summary.failureCount) max_ms=\(String(format: "%.1f", summary.slowestMilliseconds)) total_ms=\(String(format: "%.1f", summary.totalMilliseconds))"
            )
        }
        if summary.writeCount > 0 {
            speciesXMPFlushToken &+= 1
        }
        // Reconcile durable XMP failure state: paths that recovered clear, paths
        // that failed (still pending) are retained.
        for path in summary.succeededSidecarPaths { failedXMPSidecars.remove(path) }
        for path in summary.failedSidecarPaths { failedXMPSidecars.insert(path) }
        refreshSpeciesFailureMessage()
    }

    /// Recompute the observable failure surface from tracked failure state. The
    /// banner stays visible while either SQLite failures or retained XMP
    /// write-behind failures exist. Merely-pending (not-yet-failed) XMP writes
    /// are not failures and are ignored here.
    private func refreshSpeciesFailureMessage() {
        if failedSpeciesEdits.isEmpty && failedXMPSidecars.isEmpty {
            speciesPersistenceFailureMessage = nil
        } else {
            speciesPersistenceFailureMessage = Self.persistenceFailureMessage
        }
    }

    private static let persistenceFailureMessage = "species_persistence_failed"

    /// Drain SQLite work then flush the write-behind XMP queue deterministically.
    /// Used by tests, resign-active, and termination — never waits on the
    /// debounce timer.
    @MainActor
    func flushPendingPersistence() async {
        await pendingMutationTask?.value
        let summary = await xmpQueue.flush()
        handleXMPFlush(summary)
    }

    /// Retry the latest failed species snapshots (SQLite) and re-flush any
    /// pending/failed write-behind XMP. Retains each failure's original
    /// folder/database so it works even after a folder switch.
    @MainActor
    @discardableResult
    func retrySpeciesPersistence() -> Task<Void, Never> {
        guard hasSpeciesPersistenceFailure else { return completedMutationTask() }
        let failures = Array(failedSpeciesEdits.values)
        return enqueueMutation { state in
            // Group SQLite retries by their captured database.
            var order: [ObjectIdentifier] = []
            var grouped: [ObjectIdentifier: (database: ReportDatabase, snapshots: [SpeciesSnapshot], ids: [UUID], maxGeneration: Int)] = [:]
            for failure in failures {
                let key = ObjectIdentifier(failure.database)
                if var group = grouped[key] {
                    group.snapshots.append(failure.snapshot)
                    group.ids.append(failure.snapshot.id)
                    group.maxGeneration = max(group.maxGeneration, failure.generation)
                    grouped[key] = group
                } else {
                    order.append(key)
                    grouped[key] = (failure.database, [failure.snapshot], [failure.snapshot.id], failure.generation)
                }
            }
            for key in order {
                guard let group = grouped[key] else { continue }
                do {
                    let result = try await state.mutationWorker.persistSpecies(
                        database: group.database,
                        snapshots: group.snapshots
                    )
                    await state.xmpQueue.enqueue(result.written)
                    for id in group.ids {
                        if let failed = state.failedSpeciesEdits[id],
                           failed.generation <= group.maxGeneration {
                            state.failedSpeciesEdits.removeValue(forKey: id)
                            if let optimistic = state.pendingOptimisticSpecies[id],
                               optimistic.generation <= group.maxGeneration {
                                state.pendingOptimisticSpecies.removeValue(forKey: id)
                            }
                        }
                    }
                } catch {
                    state.logger.error("species retry (SQLite) failed: \(error)")
                }
            }
            // Re-flush pending XMP (path-keyed, so folder-independent). This
            // also retries XMP-only failures where SQLite already succeeded.
            let summary = await state.xmpQueue.flush()
            state.handleXMPFlush(summary)
            state.refreshSpeciesFailureMessage()
        }
    }

    @MainActor
    func noteSpeciesEditRowsRendered(token: Int) {
        guard token == speciesEditRenderToken,
              let pending = pendingSpeciesEditRender else {
            return
        }
        pendingSpeciesEditRender = nil
        let visibleMilliseconds = SpeciesEditProfiler.elapsedMilliseconds(
            since: pending.startedAt
        )
        SpeciesEditProfiler.signposter.emitEvent(
            "Species Rows Rendered",
            id: pending.signpostID,
            "operation: \(pending.operation, privacy: .public), targets: \(pending.targetPhotoCount), visible_ms: \(visibleMilliseconds)"
        )
        SpeciesEditProfiler.logger.info(
            "species_edit_visible operation=\(pending.operation, privacy: .public) targets=\(pending.targetPhotoCount) visible_ms=\(visibleMilliseconds)"
        )
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
        guard let context = mutationContext(), let action = undoStack.last else {
            return completedMutationTask()
        }
        // Species undo is optimistic: apply the captured previous species to
        // observable state synchronously (mirroring the forward edit), then
        // enqueue only the species persistence. Field undo (pick/rate/reject)
        // keeps its existing persist-first restore.
        if action.kind == .species {
            undoStack.removeLast()
            let generation = nextSpeciesEditGeneration()
            let entriesByID = Dictionary(
                uniqueKeysWithValues: action.entries.map { ($0.photoID, $0) }
            )
            var affectedBurstGroups: Set<UUID> = []
            for id in entriesByID.keys {
                if let index = allPhotoIndex[id],
                   let groupID = allPhotos[index].burstGroupID {
                    affectedBurstGroups.insert(groupID)
                }
            }
            var hierarchyTargetIDs = Set(entriesByID.keys)
            if !affectedBurstGroups.isEmpty {
                for photo in allPhotos {
                    if let groupID = photo.burstGroupID,
                       affectedBurstGroups.contains(groupID) {
                        hierarchyTargetIDs.insert(photo.id)
                    }
                }
            }

            var snapshots: [SpeciesSnapshot] = []
            var hierarchyChanges: [SpeciesHierarchyChange] = []
            snapshots.reserveCapacity(action.entries.count)
            hierarchyChanges.reserveCapacity(hierarchyTargetIDs.count)
            for index in allPhotos.indices where hierarchyTargetIDs.contains(allPhotos[index].id) {
                let previous = allPhotos[index]
                var updated = previous
                if let entry = entriesByID[previous.id] {
                    updated.assignedSpecies = entry.previousAssignedSpecies
                    allPhotos[index] = updated
                    if let filteredIndex = filteredPhotoIndex[previous.id] {
                        photos[filteredIndex] = updated
                    }
                    snapshots.append(SpeciesSnapshot(
                        id: previous.id,
                        species: entry.previousAssignedSpecies
                    ))
                    pendingOptimisticSpecies[previous.id] = (
                        generation,
                        entry.previousAssignedSpecies
                    )
                }
                hierarchyChanges.append(SpeciesHierarchyChange(
                    previous: previous,
                    updated: updated
                ))
            }
            speciesEntries = SpeciesHierarchyBuilder.applySpeciesChanges(
                entries: speciesEntries,
                changes: hierarchyChanges,
                sortOrder: speciesSortOrder,
                displayName: speciesDisplayName,
                locale: speciesSortLocale
            )
            let lastID = action.entries.last?.photoID
            if let id = lastID, photos.contains(where: { $0.id == id }) {
                selection.click(id, photos: photos)
            }
            return enqueueMutation { state in
                await state.persistSpeciesSnapshots(
                    context: context,
                    snapshots: snapshots,
                    generation: generation,
                    operation: "undo",
                    profile: nil
                )
            }
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
                    photos[index].isRejected = entry.previousIsRejected
                    photos[index].assignedSpecies = entry.previousAssignedSpecies
                }
            }
            guard currentFolder == context.folder else { return }

            var lastID: UUID?
            var anySpeciesChanged = false
            for result in results {
                let photo = result.updated
                guard entriesByID[photo.id] != nil else { continue }
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

                lastID = photo.id
            }
            if anySpeciesChanged {
                buildSpeciesHierarchy()
            }
            applyFilter()
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
        photos = allPhotos.filter(photoMatchesCurrentFilter)
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
