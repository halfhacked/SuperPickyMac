import SwiftUI

/// Species with its burst groups for the sidebar hierarchy.
struct SpeciesEntry: Identifiable {
    let name: String
    let count: Int
    let burstGroups: [BurstGroupEntry]
    let singlePhotos: Int
    let isUnidentified: Bool // true if no species was detected
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
    var speciesEntries: [SpeciesEntry] = []

    // All photos from the current folder (unfiltered)
    private var allPhotos: [Photo] = []
    // Filtered photos shown in the UI
    var photos: [Photo] = []

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

    /// Load photos from the database for the selected folder.
    func loadPhotos(for folder: URL) {
        currentFolder = folder
        do {
            let db = try ReportDatabase(folderPath: folder)
            allPhotos = try db.fetchAllPhotos()
            ratingCounts = try db.ratingCounts()
            buildSpeciesHierarchy()

            photos = allPhotos
            selectedPhotoID = photos.first?.id
        } catch {
            allPhotos = []
            photos = []
            ratingCounts = [:]
            speciesEntries = []
        }
    }

    /// Build species → burst group hierarchy from loaded photos.
    private func buildSpeciesHierarchy() {
        // Group photos by species
        // Key: (displayName, isUnidentified)
        var bySpecies: [String: (photos: [Photo], isUnidentified: Bool)] = [:]
        for photo in allPhotos {
            let hasSpecies = photo.speciesScientificName != nil
            let name = photo.speciesCommonName ?? photo.speciesScientificName ?? NSLocalizedString("Unidentified", comment: "Photos with no species detected")
            var entry = bySpecies[name] ?? (photos: [], isUnidentified: !hasSpecies)
            entry.photos.append(photo)
            bySpecies[name] = entry
        }

        speciesEntries = bySpecies.map { name, entry in
            var burstMap: [UUID: [Photo]] = [:]
            var singleCount = 0
            for photo in entry.photos {
                if let groupID = photo.burstGroupID {
                    burstMap[groupID, default: []].append(photo)
                } else {
                    singleCount += 1
                }
            }

            let burstGroups = burstMap.map { groupID, groupPhotos in
                let best = groupPhotos.first { $0.isBurstBest }
                return BurstGroupEntry(
                    id: groupID,
                    count: groupPhotos.count,
                    bestFilename: best?.filename ?? groupPhotos.first?.filename
                )
            }.sorted { $0.count > $1.count }

            return SpeciesEntry(
                name: name,
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
        case nil:
            photos = allPhotos
        }
        // Update selection
        if let id = selectedPhotoID, !photos.contains(where: { $0.id == id }) {
            selectedPhotoID = photos.first?.id
        }
    }
}

struct MainView: View {
    @Environment(CullingConfig.self) private var config
    @Environment(ProcessManager.self) private var processManager
    @State private var appState = AppState()
    @State private var processingTask: Task<Void, Never>?

    private var isTestMode: Bool {
        ProcessInfo.processInfo.environment["TEST_MODE"] == "1"
    }

    var body: some View {
        NavigationSplitView {
            SourceListView(
                selection: $appState.sidebarSelection,
                folders: $appState.folders,
                ratingCounts: appState.ratingCounts,
                speciesEntries: appState.speciesEntries,
                processingFolder: appState.processingFolder,
                processingProgress: appState.processingProgress,
                onAddFolder: { pickAndProcess() },
                onRemoveFolder: { folder in
                    if appState.currentFolder == folder {
                        appState.clearPhotos()
                    }
                }
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            if appState.isEmpty {
                EmptyStateView { pickAndProcess() }
            } else {
                ContentView(
                    photos: appState.photos,
                    selectedPhotoID: $appState.selectedPhotoID,
                    selectedPhoto: appState.selectedPhoto
                )
            }
        }
        .navigationTitle("")
        .onChange(of: appState.sidebarSelection) { _, newValue in
            switch newValue {
            case .folder(let url):
                appState.loadPhotos(for: url)
            case .rating, .flying, .picks, .species, .burstGroup:
                appState.applyFilter()
            case nil:
                break
            }
        }
        .onAppear {
            if let testFolder = ProcessInfo.processInfo.environment["TEST_FOLDER"] {
                let folder = URL(fileURLWithPath: testFolder)
                // Wait for server to be ready before auto-processing
                Task {
                    if !isTestMode {
                        for _ in 0..<30 {
                            if processManager.isReady { break }
                            try? await Task.sleep(for: .seconds(1))
                        }
                    }
                    await MainActor.run {
                        startProcessing(folder: folder)
                    }
                }
            }
        }
    }

    private func pickAndProcess() {
        if isTestMode, let testFolder = ProcessInfo.processInfo.environment["TEST_FOLDER"] {
            startProcessing(folder: URL(fileURLWithPath: testFolder))
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.message = "Select a folder with bird photos to process"
        panel.prompt = "Process"

        guard panel.runModal() == .OK, let url = panel.url else { return }
        startProcessing(folder: url)
    }

    private func startProcessing(folder: URL) {
        guard isTestMode || processManager.isReady else { return }
        guard !appState.isProcessing else { return }

        let client: InferenceClient = isTestMode
            ? MockInferenceClientForUI()
            : HTTPInferenceClient(port: processManager.port)

        let pipeline = PipelineCoordinator(inferenceClient: client)

        let ratingConfig = RatingEngine.Config(
            sharpnessThreshold: config.sharpnessThreshold,
            aestheticsThreshold: config.aestheticsThreshold
        )
        let exposureEnabled = config.exposureDetectionEnabled
        let exposureThreshold = config.exposureThreshold

        // Add folder to sidebar immediately
        if !appState.folders.contains(folder) {
            appState.folders.append(folder)
        }
        appState.sidebarSelection = .folder(folder)
        appState.processingFolder = folder
        appState.processingProgress = 0

        processingTask = Task {
            await pipeline.process(
                folder: folder,
                ratingConfig: ratingConfig,
                exposureEnabled: exposureEnabled,
                exposureThreshold: exposureThreshold,
                onPhotoProcessed: {
                    await MainActor.run {
                        if pipeline.totalCount > 0 {
                            appState.processingProgress = Double(pipeline.processedCount) / Double(pipeline.totalCount)
                        }
                        appState.processingFilename = pipeline.currentFilename
                        appState.loadPhotos(for: folder)
                    }
                }
            )

            // Final reload (includes burst detection results)
            await MainActor.run {
                appState.processingFolder = nil
                appState.processingProgress = 0
                appState.loadPhotos(for: folder)
            }
            if !isTestMode { NSSound.beep() }
        }
    }
}

/// Main content area: preview on top, thumbnail strip at bottom.
struct ContentView: View {
    let photos: [Photo]
    @Binding var selectedPhotoID: UUID?
    let selectedPhoto: Photo?

    var body: some View {
        VSplitView {
            PreviewView(photo: selectedPhoto)
                .frame(minHeight: 300)

            ThumbnailStripView(
                photos: photos,
                selectedPhotoID: $selectedPhotoID
            )
            .frame(minHeight: 80, idealHeight: 120, maxHeight: 200)
        }
    }
}

struct EmptyStateView: View {
    let onSelectFolder: () -> Void

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.secondary)

            Text("Add a folder to get started")
                .font(.title3)
                .foregroundStyle(.secondary)

            Text("Process bird photos with AI to rate and organize them")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Button {
                onSelectFolder()
            } label: {
                Label("Select Folder", systemImage: "folder")
                    .padding(.horizontal, 8)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut("o", modifiers: .command)
            .accessibilityIdentifier("SelectFolderButton")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
