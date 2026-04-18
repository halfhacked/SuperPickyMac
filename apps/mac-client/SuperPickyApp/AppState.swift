import SwiftUI
import os

enum SidebarSelection: Hashable {
    case folder(URL)
    case rating(Int)
    case flying
    case picks
    case species(String)
    case burstGroup(UUID)
    case singles(String) // species name
}

/// Species with its burst groups for the sidebar hierarchy.
struct SpeciesEntry: Identifiable {
    let name: String
    let cnName: String?
    let count: Int
    let burstGroups: [BurstGroupEntry]
    let singlePhotos: Int
    let isUnidentified: Bool
    var id: String { name }
}

struct BurstGroupEntry: Identifiable {
    let id: UUID
    let count: Int
    let bestFilename: String?
}

@Observable
final class AppState {
    private let logger = Logger(subsystem: "com.superpicky.mac", category: "AppState")

    var sidebarSelection: SidebarSelection?
    var selectedPhotoID: UUID?
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

    var ratingCounts: [Int: Int] {
        var counts: [Int: Int] = [:]
        for p in allPhotos { counts[p.starRating, default: 0] += 1 }
        return counts
    }
    var flyingCount: Int { allPhotos.lazy.filter(\.isFlying).count }
    var picksCount: Int { allPhotos.lazy.filter(\.isPick).count }

    struct UndoAction {
        let photoID: UUID
        let previousRating: Int
        let previousIsPick: Bool
        let previousIsManualRating: Bool
        let wasHidden: Bool
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
        guard let id = selectedPhotoID else { return nil }
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
        currentFolder = folder
        cachedDB = nil
        undoStack = []
        let previousSelection = selectedPhotoID
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

            // Preserve selection if the photo still exists in filtered list
            if let prev = previousSelection, photos.contains(where: { $0.id == prev }) {
                selectedPhotoID = prev
            } else if selectedPhotoID == nil {
                selectedPhotoID = photos.first?.id
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

    /// O(1) incremental update — adds/removes the photo in its species
    /// bucket without touching the rest of the hierarchy.
    ///
    /// Burst-member photos take the same incremental path during ingest:
    /// the alternative (a full `SpeciesHierarchyBuilder.build` per burst
    /// photo) was O(n) on the main thread and dominated scroll latency
    /// on 1k+ photo folders. Side effect: while processing, a burst-
    /// member photo is attributed to its own species entry instead of
    /// the burst's dominant species, and burst groups don't appear in
    /// the sidebar until end-of-run. `loadPhotos` runs a correct full
    /// rebuild at completion, so the finished UI matches the previous
    /// behavior.
    private func updateSpeciesHierarchy(removing old: Photo?, adding photo: Photo) {
        if let old { remove(old) }
        add(photo)
        speciesEntries = SpeciesHierarchyBuilder.sorted(
            entries: speciesEntries,
            by: speciesSortOrder,
            displayName: speciesDisplayName,
            locale: speciesSortLocale
        )
    }

    private func add(_ photo: Photo) {
        let hasSpecies = photo.speciesScientificName != nil
        let name = photo.speciesCommonName ?? photo.speciesScientificName ?? String(localized: "Unidentified")
        if let idx = speciesEntries.firstIndex(where: { $0.name == name }) {
            let existing = speciesEntries[idx]
            speciesEntries[idx] = SpeciesEntry(
                name: existing.name,
                cnName: existing.cnName ?? photo.speciesCnName,
                count: existing.count + 1,
                burstGroups: existing.burstGroups,
                singlePhotos: existing.singlePhotos + 1,
                isUnidentified: existing.isUnidentified
            )
        } else {
            speciesEntries.append(SpeciesEntry(
                name: name,
                cnName: photo.speciesCnName,
                count: 1,
                burstGroups: [],
                singlePhotos: 1,
                isUnidentified: !hasSpecies
            ))
        }
    }

    private func remove(_ photo: Photo) {
        let name = photo.speciesCommonName ?? photo.speciesScientificName ?? String(localized: "Unidentified")
        guard let idx = speciesEntries.firstIndex(where: { $0.name == name }) else { return }
        let existing = speciesEntries[idx]
        if existing.count <= 1 && existing.burstGroups.isEmpty {
            speciesEntries.remove(at: idx)
            return
        }
        speciesEntries[idx] = SpeciesEntry(
            name: existing.name,
            cnName: existing.cnName,
            count: max(0, existing.count - 1),
            burstGroups: existing.burstGroups,
            singlePhotos: max(0, existing.singlePhotos - 1),
            isUnidentified: existing.isUnidentified
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
        case .species(let name):
            let isUnidentified = speciesEntries.first { $0.name == name }?.isUnidentified ?? false
            if isUnidentified {
                return photo.speciesScientificName == nil
            }
            return photo.speciesCommonName == name || photo.speciesScientificName == name
        case .burstGroup(let groupID):
            return photo.burstGroupID == groupID
        case .singles(let speciesName):
            guard photo.burstGroupID == nil else { return false }
            let isUnidentified = speciesEntries.first { $0.name == speciesName }?.isUnidentified ?? false
            if isUnidentified {
                return photo.speciesScientificName == nil
            }
            return photo.speciesCommonName == speciesName || photo.speciesScientificName == speciesName
        }
    }

    /// Clear all photo data (when folder is removed).
    func clearPhotos() {
        allPhotos = []
        photos = []
        allPhotoIndex = [:]
        filteredPhotoIndex = [:]
        speciesEntries = []
        selectedPhotoID = nil
        currentFolder = nil
        undoStack = []
    }

    /// Mutate a photo, persist to DB + XMP, and update in-memory arrays.
    /// Saves undo state before mutation. The `updateView` closure handles
    /// how the filtered `photos` array should change (update in-place vs remove).
    private func mutatePhoto(
        id: UUID, wasHidden: Bool = false,
        _ mutate: (inout Photo) -> Void,
        updateView: ((_ photo: Photo) -> Void)? = nil
    ) {
        do {
            let database = try db()
            guard var photo = try database.fetchPhoto(id: id) else { return }
            undoStack.append(UndoAction(
                photoID: id, previousRating: photo.starRating,
                previousIsPick: photo.isPick, previousIsManualRating: photo.isManualRating,
                wasHidden: wasHidden
            ))
            if undoStack.count > Self.maxUndoDepth {
                undoStack.removeFirst()
            }
            mutate(&photo)
            try database.save(&photo)      // DB write FIRST
            try? XMPWriter.write(photo: photo)
            // Only update in-memory state after successful DB write:
            if let idx = allPhotoIndex[id] {
                allPhotos[idx] = photo
            }
            if let update = updateView {
                update(photo)
            } else if let idx = filteredPhotoIndex[id] {
                photos[idx] = photo
            }
        } catch {
            logger.error("mutatePhoto failed: \(error)")
        }
    }

    func ratePhoto(id: UUID, rating: Int) {
        mutatePhoto(id: id) { photo in
            photo.starRating = rating
            photo.isManualRating = true
        }
    }

    func togglePick(id: UUID) {
        mutatePhoto(id: id) { photo in
            photo.isPick.toggle()
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
        undoStack.removeAll { $0.photoID == id }

        logger.info("Deleted photo: \(photo.filename)")
    }

    /// Override the species name for a photo. Persists to DB and XMP sidecar.
    func correctSpecies(id: UUID, commonName: String) {
        let trimmed = commonName.trimmingCharacters(in: .whitespaces)
        mutatePhoto(id: id) { photo in
            photo.speciesCommonName = trimmed.isEmpty ? nil : trimmed
        }
        buildSpeciesHierarchy()
    }

    func rejectPhoto(id: UUID) {
        mutatePhoto(id: id, wasHidden: true, { photo in
            photo.starRating = 0
            photo.isManualRating = true
        }, updateView: { [self] _ in
            self.photos.removeAll { $0.id == id }
            self.rebuildFilteredPhotoIndex()
        })
    }

    func undoLastAction() {
        guard let action = undoStack.popLast() else { return }
        do {
            let database = try db()
            guard var photo = try database.fetchPhoto(id: action.photoID) else { return }
            photo.starRating = action.previousRating
            photo.isPick = action.previousIsPick
            photo.isManualRating = action.previousIsManualRating
            try database.save(&photo)
            try? XMPWriter.write(photo: photo)

            if let idx = allPhotoIndex[action.photoID] {
                allPhotos[idx] = photo
            }

            if action.wasHidden {
                filteredPhotoIndex[photo.id] = photos.count
                photos.append(photo)
            } else if let idx = filteredPhotoIndex[action.photoID] {
                photos[idx] = photo
            }

            selectedPhotoID = action.photoID
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
        case .species(let name):
            // Find the entry to check if it's the unidentified group
            let isUnidentified = speciesEntries.first { $0.name == name }?.isUnidentified ?? false
            if isUnidentified {
                photos = allPhotos.filter { $0.speciesScientificName == nil }
            } else {
                photos = allPhotos.filter {
                    $0.speciesCommonName == name || $0.speciesScientificName == name
                }
            }
        case .burstGroup(let groupID):
            photos = allPhotos.filter { $0.burstGroupID == groupID }
        case .singles(let speciesName):
            let isUnidentified = speciesEntries.first { $0.name == speciesName }?.isUnidentified ?? false
            photos = allPhotos.filter { photo in
                photo.burstGroupID == nil && (isUnidentified
                    ? photo.speciesScientificName == nil
                    : (photo.speciesCommonName == speciesName || photo.speciesScientificName == speciesName))
            }
        case nil:
            photos = allPhotos
        }
        rebuildFilteredPhotoIndex()
        // Update selection
        if let id = selectedPhotoID, filteredPhotoIndex[id] == nil {
            selectedPhotoID = photos.first?.id
        }
    }
}
