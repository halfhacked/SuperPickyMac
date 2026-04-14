import SwiftUI

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
    var sidebarSelection: SidebarSelection?
    var selectedPhotoID: UUID?
    var folders: [URL] = []
    var ratingCounts: [Int: Int] = [:]
    var flyingCount: Int = 0
    var picksCount: Int = 0
    var speciesEntries: [SpeciesEntry] = []

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
    var lastAction: UndoAction?

    private var cachedDB: ReportDatabase?

    // Per-folder processing state
    var processingFolder: URL?
    var processingProgress: Double = 0
    var processingFilename: String = ""
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
    func loadPhotos(for folder: URL) {
        currentFolder = folder
        cachedDB = nil
        lastAction = nil
        let previousSelection = selectedPhotoID
        do {
            let database = try ReportDatabase(folderPath: folder)
            cachedDB = database
            allPhotos = try database.fetchAllPhotos()
            ratingCounts = try database.ratingCounts()
            flyingCount = allPhotos.filter { $0.isFlying }.count
            picksCount = allPhotos.filter { $0.isPick }.count
            buildSpeciesHierarchy()

            // Re-apply current filter instead of resetting to all
            applyFilter()

            // Preserve selection if the photo still exists in filtered list
            if let prev = previousSelection, photos.contains(where: { $0.id == prev }) {
                selectedPhotoID = prev
            } else if selectedPhotoID == nil {
                selectedPhotoID = photos.first?.id
            }
        } catch {
            allPhotos = []
            photos = []
            ratingCounts = [:]
            speciesEntries = []
        }
    }

    /// Build species → burst group hierarchy from loaded photos.
    private func buildSpeciesHierarchy() {
        // Assign each burst to its dominant species by highest confidence ID.
        // A burst spanning multiple species classifications appears only once.
        var burstToSpecies: [UUID: String] = [:]
        var burstBestConfidence: [UUID: (species: String, confidence: Float)] = [:]
        var burstPhotos: [UUID: [Photo]] = [:]

        for photo in allPhotos {
            guard let groupID = photo.burstGroupID else { continue }
            burstPhotos[groupID, default: []].append(photo)

            guard let name = photo.speciesCommonName ?? photo.speciesScientificName else { continue }
            let confidence = photo.speciesConfidence ?? 0
            if let current = burstBestConfidence[groupID] {
                if confidence > current.confidence {
                    burstBestConfidence[groupID] = (name, confidence)
                }
            } else {
                burstBestConfidence[groupID] = (name, confidence)
            }
        }

        for groupID in burstPhotos.keys {
            burstToSpecies[groupID] = burstBestConfidence[groupID]?.species ?? "Unidentified"
        }

        // Group photos by species
        var bySpecies: [String: (photos: [Photo], isUnidentified: Bool)] = [:]
        for photo in allPhotos {
            let hasSpecies = photo.speciesScientificName != nil
            let name = photo.speciesCommonName ?? photo.speciesScientificName ?? String(localized: "Unidentified")
            var entry = bySpecies[name] ?? (photos: [], isUnidentified: !hasSpecies)
            entry.photos.append(photo)
            bySpecies[name] = entry
        }

        speciesEntries = bySpecies.map { name, entry in
            // Only include burst groups whose dominant species matches this entry
            var burstGroupIDs: Set<UUID> = []
            var singleCount = 0
            for photo in entry.photos {
                if let groupID = photo.burstGroupID {
                    if burstToSpecies[groupID] == name {
                        burstGroupIDs.insert(groupID)
                    }
                    // Photos in bursts owned by another species don't count as singles
                } else {
                    singleCount += 1
                }
            }

            let burstGroups = burstGroupIDs.map { groupID in
                let groupPhotos = burstPhotos[groupID] ?? []
                let best = groupPhotos.first { $0.isBurstBest }
                return BurstGroupEntry(
                    id: groupID,
                    count: groupPhotos.count,
                    bestFilename: best?.filename ?? groupPhotos.first?.filename
                )
            }.sorted { $0.count > $1.count }

            return SpeciesEntry(
                name: name,
                cnName: entry.photos.first?.speciesCnName,
                count: entry.photos.count,
                burstGroups: burstGroups,
                singlePhotos: singleCount,
                isUnidentified: entry.isUnidentified
            )
        }.sorted {
            // Unidentified always first, then by count
            if $0.isUnidentified != $1.isUnidentified { return $0.isUnidentified }
            return $0.count > $1.count
        }
    }

    /// Clear all photo data (when folder is removed).
    func clearPhotos() {
        allPhotos = []
        photos = []
        ratingCounts = [:]
        speciesEntries = []
        selectedPhotoID = nil
        currentFolder = nil
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
            lastAction = UndoAction(
                photoID: id, previousRating: photo.starRating,
                previousIsPick: photo.isPick, previousIsManualRating: photo.isManualRating,
                wasHidden: wasHidden
            )
            mutate(&photo)
            try database.save(&photo)
            try? XMPWriter.write(photo: photo)

            if let idx = allPhotos.firstIndex(where: { $0.id == id }) {
                allPhotos[idx] = photo
            }
            if let update = updateView {
                update(photo)
            } else if let idx = photos.firstIndex(where: { $0.id == id }) {
                photos[idx] = photo
            }

            ratingCounts = (try? database.ratingCounts()) ?? ratingCounts
            picksCount = allPhotos.filter { $0.isPick }.count
        } catch {
            // Silently fail
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

    func rejectPhoto(id: UUID) {
        mutatePhoto(id: id, wasHidden: true, { photo in
            photo.starRating = 0
            photo.isManualRating = true
        }, updateView: { [self] _ in
            self.photos.removeAll { $0.id == id }
        })
    }

    func undoLastAction() {
        guard let action = lastAction else { return }
        lastAction = nil
        do {
            let database = try db()
            guard var photo = try database.fetchPhoto(id: action.photoID) else { return }
            photo.starRating = action.previousRating
            photo.isPick = action.previousIsPick
            photo.isManualRating = action.previousIsManualRating
            try database.save(&photo)
            try? XMPWriter.write(photo: photo)

            if let idx = allPhotos.firstIndex(where: { $0.id == action.photoID }) {
                allPhotos[idx] = photo
            }

            if action.wasHidden {
                photos.append(photo)
            } else if let idx = photos.firstIndex(where: { $0.id == action.photoID }) {
                photos[idx] = photo
            }

            selectedPhotoID = action.photoID
            ratingCounts = (try? database.ratingCounts()) ?? ratingCounts
            picksCount = allPhotos.filter { $0.isPick }.count
        } catch {
            // Silently fail
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
        // Update selection
        if let id = selectedPhotoID, !photos.contains(where: { $0.id == id }) {
            selectedPhotoID = photos.first?.id
        }
    }
}
