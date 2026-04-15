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
    private var undoStack: [UndoAction] = []
    private static let maxUndoDepth = 20
    var canUndo: Bool { !undoStack.isEmpty }

    private var cachedDB: ReportDatabase?

    // Per-folder processing state
    var processingFolder: URL?
    var processingProgress: Double = 0
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
            ratingCounts = try database.ratingCounts()
            flyingCount = allPhotos.filter { $0.isFlying }.count
            picksCount = allPhotos.filter { $0.isPick }.count
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
            ratingCounts = [:]
            speciesEntries = []
        }
    }

    /// Build species → burst group hierarchy from loaded photos.
    private func buildSpeciesHierarchy() {
        speciesEntries = SpeciesHierarchyBuilder.build(from: allPhotos)
    }

    /// Clear all photo data (when folder is removed).
    func clearPhotos() {
        allPhotos = []
        photos = []
        ratingCounts = [:]
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
        undoStack.removeAll { $0.photoID == id }

        ratingCounts = (try? database.ratingCounts()) ?? ratingCounts
        picksCount = allPhotos.filter { $0.isPick }.count

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
        // Update selection
        if let id = selectedPhotoID, !photos.contains(where: { $0.id == id }) {
            selectedPhotoID = photos.first?.id
        }
    }
}
