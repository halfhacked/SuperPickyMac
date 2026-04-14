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

struct MainView: View {
    @Environment(CullingConfig.self) private var config
    @Environment(ProcessManager.self) private var processManager
    @State private var appState = AppState()
    @State private var processingTask: Task<Void, Never>?
    @State private var isExporting = false
    @State private var exportProgress = 0
    @State private var exportTotal = 0
    @State private var showExportComplete = false
    @State private var exportResultMessage = ""
    @State private var exportDestination: URL?
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
                    },
                    onTogglePick: { id in
                        appState.togglePick(id: id)
                    },
                    onRejectPhoto: { id in
                        appState.rejectPhoto(id: id)
                    },
                    onUndo: {
                        appState.undoLastAction()
                    },
                    onExportPicks: {
                        exportPicks()
                    }
                )
            }
        }
        .navigationTitle("")
        .onChange(of: appState.sidebarSelection) { _, newValue in
            switch newValue {
            case .folder(let url):
                appState.loadPhotos(for: url)
            case .rating, .flying, .picks, .species, .burstGroup, .singles:
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
        .sheet(isPresented: $isExporting) {
            VStack(spacing: 16) {
                Text("Exporting Picks...")
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
        .alert("Export", isPresented: $showExportComplete) {
            if let dest = exportDestination {
                Button("Reveal in Finder") {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dest.path)
                }
            }
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportResultMessage)
        }
    }

    private func exportPicks() {
        guard let folder = appState.currentFolder else { return }
        let picks = appState.pickedPhotos
        guard !picks.isEmpty else {
            exportResultMessage = "No picks to export"
            showExportComplete = true
            return
        }

        let destination = ExportService.picksDestination(for: folder)
        exportDestination = destination
        exportProgress = 0
        exportTotal = picks.count
        isExporting = true

        Task {
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let result = try await ExportService.export(
                    photos: picks,
                    to: destination,
                    onProgress: { current, total in
                        exportProgress = current
                        exportTotal = total
                    }
                )
                isExporting = false
                exportResultMessage = "Exported \(result.exportedCount) photos"
                if result.skippedCount > 0 {
                    exportResultMessage += ", \(result.skippedCount) skipped"
                }
                showExportComplete = true
            } catch {
                isExporting = false
                exportResultMessage = "Export failed: \(error.localizedDescription)"
                showExportComplete = true
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
    var onTogglePick: ((UUID) -> Void)?
    var onRejectPhoto: ((UUID) -> Void)?
    var onUndo: (() -> Void)?
    var onExportPicks: (() -> Void)?
    @Environment(CullingConfig.self) private var config
    @State private var minimumStars: Int = 0
    @State private var topBurstOnly: Bool = false
    @State private var pickedOnly: Bool = false
    @State private var showExifPanel = true
    @State private var showFullscreen = false
    @State private var zoomState = ZoomState()
    @State private var fullscreenZoomState = ZoomState()
    @State private var previewSize: CGSize = .zero
    @State private var mouseInPreview: CGPoint = .zero
    @State private var brightnessAdj: Double = 0
    @State private var showCompare = false
    @State private var showNoPhotosAlert = false

    private var filteredPhotos: [Photo] {
        var result = photos
        if minimumStars > 0 {
            result = result.filter { $0.starRating >= minimumStars }
        }
        if topBurstOnly {
            result = result.filter { $0.burstGroupID == nil || $0.isBurstBest }
        }
        if pickedOnly {
            result = result.filter { $0.isPick }
        }
        return result
    }

    var body: some View {
        VSplitView {
            ZStack(alignment: .topTrailing) {
                PreviewView(photo: selectedPhoto, zoomState: zoomState,
                            brightnessAdjustment: brightnessAdj,
                            mouseInView: $mouseInPreview, viewSize: $previewSize)

                if showExifPanel, let photo = selectedPhoto {
                    ExifPanelView(photo: photo)
                        .transition(.move(edge: .trailing))
                }
            }
            .frame(minHeight: 300)

            VStack(spacing: 0) {
                // Star filter bar + photo counter
                HStack(spacing: 8) {
                    Text("≥")
                        .font(.caption.weight(.bold))
                        .foregroundStyle(minimumStars > 0 ? .primary : .secondary)

                    HStack(spacing: 2) {
                        ForEach(1...5, id: \.self) { n in
                            Image(systemName: n <= minimumStars ? "star.fill" : "star")
                                .font(.system(size: 10))
                                .foregroundStyle(n <= minimumStars ? .primary : .secondary)
                                .onTapGesture {
                                    minimumStars = minimumStars == n ? 0 : n
                                }
                        }
                    }
                    .accessibilityIdentifier("StarFilter")
                    .help(minimumStars > 0 ? "Rating ≥ \(minimumStars) (⌘0 to reset)" : "Filter by minimum rating (⌘1–5)")

                    Divider().frame(height: 12)

                    Button {
                        topBurstOnly.toggle()
                    } label: {
                        Image(systemName: topBurstOnly ? "crown.fill" : "crown")
                            .font(.system(size: 10))
                            .foregroundStyle(topBurstOnly ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(topBurstOnly ? "Showing burst best only — click to show all" : "Show only the best photo from each burst")
                    .accessibilityIdentifier("TopBurstFilter")

                    Button {
                        pickedOnly.toggle()
                    } label: {
                        Image(systemName: pickedOnly ? "flag.fill" : "flag")
                            .font(.system(size: 10))
                            .foregroundStyle(pickedOnly ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(pickedOnly ? "Showing picks only — click to show all" : "Show only flagged photos (P to pick)")
                    .accessibilityIdentifier("PickedFilter")

                    Spacer()

                    if brightnessAdj != 0 {
                        Text("EV \(brightnessAdj > 0 ? "+" : "")\(String(format: "%.2f", brightnessAdj))")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }

                    Text("\(filteredPhotos.count) of \(photos.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("PhotoCounter")
                        .accessibilityValue("\(filteredPhotos.count) of \(photos.count)")
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
                .background(.bar)

                ThumbnailStripView(
                    photos: filteredPhotos,
                    selectedPhotoID: $selectedPhotoID
                )
            }
            .frame(minHeight: 80, idealHeight: 100, maxHeight: 140)
        }
        .background(Color(nsColor: .controlBackgroundColor))
        .background(KeyboardMonitor { key in
            return handleKey(key)
        })
        .overlay {
            if showFullscreen {
                FullscreenViewer(
                    photos: filteredPhotos,
                    selectedPhotoID: $selectedPhotoID,
                    isPresented: $showFullscreen,
                    onRatePhoto: onRatePhoto,
                    zoomState: fullscreenZoomState
                )
            }
            if showCompare {
                CompareView(
                    photos: filteredPhotos,
                    selectedPhotoID: $selectedPhotoID,
                    isPresented: $showCompare,
                    onRatePhoto: onRatePhoto,
                    onTogglePick: onTogglePick
                )
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Button {
                    onExportPicks?()
                } label: {
                    Label("Export Picks", systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("ExportPicksButton")
                .help("Export picked photos with XMP sidecars (⌘E)")
                .keyboardShortcut("e", modifiers: .command)
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
        .alert("No Photos", isPresented: $showNoPhotosAlert) {
            Button("OK", role: .cancel) {}
        } message: {
            Text("No photos match the current filter")
        }
        .onChange(of: photos.count) { _, _ in
            minimumStars = 0
            topBurstOnly = false
            pickedOnly = false
        }
        .onChange(of: selectedPhotoID) { _, _ in
            brightnessAdj = 0
        }
    }

    private func handleKey(_ key: KeyboardMonitor.KeyEvent) -> Bool {
        // Arrow keys navigate photos
        if key.isLeftArrow { navigatePhoto(direction: -1); return true }
        if key.isRightArrow { navigatePhoto(direction: 1); return true }

        // Escape exits fullscreen
        if key.isEscape && showFullscreen { showFullscreen = false; return true }

        // Cmd+Z: undo
        if key.modifiers.contains(.command), key.characters == "z" {
            onUndo?()
            return true
        }

        // Cmd+0-5: set minimum star filter
        if key.modifiers.contains(.command),
           let char = key.characters.first,
           let digit = char.wholeNumberValue,
           (0...5).contains(digit) {
            minimumStars = digit
            return true
        }

        switch key.characters {
        case "i":
            withAnimation(.easeInOut(duration: 0.2)) { showExifPanel.toggle() }
            return true
        case "f":
            showFullscreen.toggle()
            return true
        case "c":
            if filteredPhotos.count >= 2 { showCompare.toggle() }
            return true
        case "p":
            guard let id = selectedPhoto?.id else { return false }
            onTogglePick?(id)
            if config.autoAdvance { navigatePhoto(direction: 1) }
            return true
        case "x":
            guard let id = selectedPhoto?.id else { return false }
            navigatePhoto(direction: 1, fallbackToPrevious: true)
            onRejectPhoto?(id)
            return true
        case "0", "1", "2", "3", "4", "5":
            if let digit = key.characters.first?.wholeNumberValue {
                rateSelectedPhoto(digit)
                if config.autoAdvance { navigatePhoto(direction: 1) }
            }
            return true
        case "z":
            guard let photo = selectedPhoto else { return false }
            let imagePixelWidth = ImageLoader.pixelWidth(path: photo.filePath) ?? previewSize.width * 2

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
        case "=", "+":
            brightnessAdj = min(brightnessAdj + 0.05, 0.5)
            return true
        case "-":
            brightnessAdj = max(brightnessAdj - 0.05, -0.5)
            return true
        default: return false
        }
    }

    /// Navigate to the next/previous photo. Returns the target ID (nil if can't navigate).
    /// When `fallbackToPrevious` is true and can't go forward, falls back to previous photo.
    @discardableResult
    private func navigatePhoto(direction: Int, fallbackToPrevious: Bool = false) -> UUID? {
        guard let currentID = selectedPhotoID,
              let currentIndex = filteredPhotos.firstIndex(where: { $0.id == currentID }) else { return nil }
        let newIndex = currentIndex + direction
        if filteredPhotos.indices.contains(newIndex) {
            selectedPhotoID = filteredPhotos[newIndex].id
            return filteredPhotos[newIndex].id
        } else if fallbackToPrevious, currentIndex > 0 {
            selectedPhotoID = filteredPhotos[currentIndex - 1].id
            return filteredPhotos[currentIndex - 1].id
        }
        return nil
    }

    private func rateSelectedPhoto(_ rating: Int) {
        guard let id = selectedPhoto?.id else { return }
        onRatePhoto?(id, rating)
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
