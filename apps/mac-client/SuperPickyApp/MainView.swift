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
    var flyingCount: Int = 0
    var picksCount: Int = 0
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
    /// Preserves current filter and selection when possible.
    func loadPhotos(for folder: URL) {
        currentFolder = folder
        let previousSelection = selectedPhotoID
        do {
            let db = try ReportDatabase(folderPath: folder)
            allPhotos = try db.fetchAllPhotos()
            ratingCounts = try db.ratingCounts()
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

    /// Update a photo's star rating manually and persist to the database.
    func ratePhoto(id: UUID, rating: Int) {
        guard let folder = currentFolder else { return }
        do {
            let db = try ReportDatabase(folderPath: folder)
            guard var photo = try db.fetchPhoto(id: id) else { return }
            photo.starRating = rating
            photo.isManualRating = true
            try db.save(&photo)

            // Update in-memory arrays
            if let idx = allPhotos.firstIndex(where: { $0.id == id }) {
                allPhotos[idx].starRating = rating
                allPhotos[idx].isManualRating = true
            }
            if let idx = photos.firstIndex(where: { $0.id == id }) {
                photos[idx].starRating = rating
                photos[idx].isManualRating = true
            }

            // Refresh rating counts
            ratingCounts = (try? db.ratingCounts()) ?? ratingCounts
        } catch {
            // Silently fail — rating not persisted
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
    @AppStorage("lastFolderPath") private var lastFolderPath: String = ""

    private var isTestMode: Bool {
        ProcessInfo.processInfo.environment["TEST_MODE"] == "1"
    }

    var body: some View {
        NavigationSplitView {
            SourceListView(
                selection: $appState.sidebarSelection,
                folders: $appState.folders,
                ratingCounts: appState.ratingCounts,
                flyingCount: appState.flyingCount,
                picksCount: appState.picksCount,
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
                    selectedPhoto: appState.selectedPhoto,
                    onRatePhoto: { id, rating in
                        appState.ratePhoto(id: id, rating: rating)
                    }
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
            } else if !lastFolderPath.isEmpty {
                let folder = URL(fileURLWithPath: lastFolderPath)
                // Only restore if .report.db exists (folder was previously processed)
                let dbPath = folder.appendingPathComponent(".report.db").path
                if FileManager.default.fileExists(atPath: dbPath) {
                    appState.folders.append(folder)
                    appState.sidebarSelection = .folder(folder)
                    appState.loadPhotos(for: folder)
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
        let writeKeywords = config.writeKeywords
        let keywordFormat = config.keywordFormat

        // Add folder to sidebar immediately and remember it
        if !appState.folders.contains(folder) {
            appState.folders.append(folder)
        }
        lastFolderPath = folder.path
        appState.sidebarSelection = .folder(folder)
        appState.processingFolder = folder
        appState.processingProgress = 0

        processingTask = Task {
            await pipeline.process(
                folder: folder,
                ratingConfig: ratingConfig,
                exposureEnabled: exposureEnabled,
                exposureThreshold: exposureThreshold,
                writeKeywords: writeKeywords,
                keywordFormat: keywordFormat,
                onPhotoProcessed: {
                    await MainActor.run {
                        if pipeline.totalCount > 0 {
                            appState.processingProgress = Double(pipeline.processedCount) / Double(pipeline.totalCount)
                        }
                        appState.processingFilename = pipeline.currentFilename
                        // Reload UI every 5 photos to avoid jarring per-photo re-renders
                        if pipeline.processedCount % 5 == 0 {
                            appState.loadPhotos(for: folder)
                        }
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
    var onRatePhoto: ((UUID, Int) -> Void)?
    @State private var showExifPanel = true
    @State private var showFullscreen = false
    @State private var zoomState = ZoomState()
    @State private var fullscreenZoomState = ZoomState()
    @State private var previewSize: CGSize = .zero
    @State private var mouseInPreview: CGPoint = .zero
    @State private var isExporting = false
    @State private var exportProgress = 0
    @State private var exportTotal = 0
    @State private var showExportComplete = false
    @State private var exportResultMessage = ""
    @State private var showNoPhotosAlert = false

    var body: some View {
        VSplitView {
            ZStack(alignment: .topTrailing) {
                PreviewView(photo: selectedPhoto, zoomState: zoomState)
                    .onContinuousHover { phase in
                        if case .active(let location) = phase {
                            mouseInPreview = location
                        }
                    }
                    .background(GeometryReader { geo in
                        Color.clear.onAppear { previewSize = geo.size }
                            .onChange(of: geo.size) { _, s in previewSize = s }
                    })

                if showExifPanel, let photo = selectedPhoto {
                    ExifPanelView(photo: photo)
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(minHeight: 300)

            ThumbnailStripView(
                photos: photos,
                selectedPhotoID: $selectedPhotoID
            )
            .frame(minHeight: 60, idealHeight: 80, maxHeight: 120)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .background(KeyboardMonitor { key in
            return handleKey(key)
        })
        .overlay {
            if showFullscreen {
                FullscreenViewer(
                    photos: photos,
                    selectedPhotoID: $selectedPhotoID,
                    isPresented: $showFullscreen,
                    onRatePhoto: onRatePhoto,
                    zoomState: fullscreenZoomState
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    exportPhotos()
                } label: {
                    Label("Export", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("ExportButton")
                .help("Export filtered photos with XMP sidecars")
                .disabled(isExporting)
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showExifPanel.toggle()
                    }
                } label: {
                    Image(systemName: showExifPanel ? "info.circle.fill" : "info.circle")
                }
                .accessibilityIdentifier("ExifToggle")
                .help("Toggle EXIF Info (I)")
            }
        }
        .sheet(isPresented: $isExporting) {
            VStack(spacing: 16) {
                Text("Exporting Photos...")
                    .font(.headline)
                ProgressView(value: Double(exportProgress), total: Double(max(exportTotal, 1)))
                    .progressViewStyle(.linear)
                    .frame(width: 300)
                Text("\(exportProgress) of \(exportTotal)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(40)
            .interactiveDismissDisabled()
        }
        .alert("Export Complete", isPresented: $showExportComplete) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportResultMessage)
        }
        .alert("No Photos", isPresented: $showNoPhotosAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("No photos match the current filter")
        }
    }

    private func handleKey(_ key: KeyboardMonitor.KeyEvent) -> Bool {
        // Arrow keys navigate photos
        if key.isLeftArrow { navigatePhoto(direction: -1); return true }
        if key.isRightArrow { navigatePhoto(direction: 1); return true }

        // Escape exits fullscreen
        if key.isEscape && showFullscreen { showFullscreen = false; return true }

        switch key.characters {
        case "i":
            withAnimation(.easeInOut(duration: 0.2)) { showExifPanel.toggle() }
            return true
        case "f":
            showFullscreen.toggle()
            return true
        case "0": rateSelectedPhoto(0); return true
        case "1": rateSelectedPhoto(1); return true
        case "2": rateSelectedPhoto(2); return true
        case "3": rateSelectedPhoto(3); return true
        case "4": rateSelectedPhoto(4); return true
        case "5": rateSelectedPhoto(5); return true
        case "z":
            guard let photo = selectedPhoto else { return false }
            let imagePixelWidth: CGFloat
            if let source = CGImageSourceCreateWithURL(URL(fileURLWithPath: photo.filePath) as CFURL, nil),
               let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
               let w = props[kCGImagePropertyPixelWidth as String] as? CGFloat {
                imagePixelWidth = w
            } else {
                imagePixelWidth = previewSize.width * 2
            }

            let activeZoom = showFullscreen ? fullscreenZoomState : zoomState
            let viewSize = showFullscreen
                ? (NSApp.keyWindow?.frame.size ?? previewSize)
                : previewSize

            activeZoom.toggleFitActualPixelsAt(
                imagePixelWidth: imagePixelWidth,
                viewSize: viewSize,
                mouseInView: mouseInPreview
            )
            return true
        default: return false
        }
    }

    private func navigatePhoto(direction: Int) {
        guard let currentID = selectedPhotoID,
              let currentIndex = photos.firstIndex(where: { $0.id == currentID }) else { return }
        let newIndex = currentIndex + direction
        guard photos.indices.contains(newIndex) else { return }
        selectedPhotoID = photos[newIndex].id
    }

    private func rateSelectedPhoto(_ rating: Int) {
        guard let id = selectedPhoto?.id else { return }
        onRatePhoto?(id, rating)
    }

    private func exportPhotos() {
        guard !photos.isEmpty else {
            showNoPhotosAlert = true
            return
        }

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.message = "Choose a destination folder for exported photos"
        panel.prompt = "Export"

        guard panel.runModal() == .OK, let destination = panel.url else { return }

        let photosToExport = photos
        exportProgress = 0
        exportTotal = photosToExport.count
        isExporting = true

        Task {
            do {
                let result = try await ExportService.export(
                    photos: photosToExport,
                    to: destination,
                    onProgress: { current, total in
                        exportProgress = current
                        exportTotal = total
                    }
                )
                isExporting = false
                exportResultMessage = "Exported \(result.exportedCount) photos to \(destination.path)"
                if result.skippedCount > 0 {
                    exportResultMessage += "\n\(result.skippedCount) skipped (already exist)"
                }
                if result.failedCount > 0 {
                    exportResultMessage += "\n\(result.failedCount) failed"
                }
                showExportComplete = true
            } catch {
                isExporting = false
                exportResultMessage = "Export failed: \(error.localizedDescription)"
                showExportComplete = true
            }
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
