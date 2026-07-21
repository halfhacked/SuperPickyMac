import SwiftUI
import SuperPickyInference
import os

/// Coalesces per-photo `onPhotoProcessed` deliveries into batched main-actor
/// commits.
@MainActor
final class PhotoIngestBatcher {
    private let appState: AppState
    private let pipeline: PipelineCoordinator
    private var pending: [Photo] = []
    private var scheduled: Bool = false
    private static let flushDelayNanos: UInt64 = 100_000_000

    init(appState: AppState, pipeline: PipelineCoordinator) {
        self.appState = appState
        self.pipeline = pipeline
    }

    func enqueue(_ photo: Photo?) async {
        if let photo { pending.append(photo) }
        if scheduled { return }
        scheduled = true
        Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: Self.flushDelayNanos)
            self?.flush()
        }
    }

    func flush() {
        scheduled = false
        let p = pipeline.processedCount
        let t = pipeline.totalCount
        if appState.processingProcessed != p { appState.processingProcessed = p }
        if appState.processingTotal != t { appState.processingTotal = t }
        if t > 0 {
            let progress = Double(p) / Double(t)
            if appState.processingProgress != progress {
                appState.processingProgress = progress
            }
        }
        guard !pending.isEmpty else { return }
        let batch = pending
        pending.removeAll(keepingCapacity: true)
        for photo in batch {
            appState.appendProcessedPhoto(photo)
        }
    }
}

struct MainView: View {
    @Environment(CullingConfig.self) private var config
    let modelState: ModelDownloadState
    @State private var appState = AppState()
    /// Bundled species reference DB (~11 k entries), loaded and indexed away
    /// from the main actor for species autocomplete.
    @State private var speciesDB: SpeciesDatabase? = nil
    @State private var processingTask: Task<Void, Never>?
    @State private var isExporting = false
    @State private var exportProgress = 0
    @State private var exportTotal = 0
    @State private var showExportComplete = false
    @State private var exportResultMessage = ""
    @State private var exportDestination: URL?

    private static let foldersKey = "savedFolderPaths"

    private var isTestMode: Bool {
        ProcessInfo.processInfo.environment["TEST_MODE"] == "1"
    }

    var body: some View {
        NavigationSplitView {
            SourceListView(
                selection: $appState.sidebarSelection,
                folders: $appState.folders,
                ratingCounts: appState.ratingCounts,
                rejectedCount: appState.rejectedCount,
                flyingCount: appState.flyingCount,
                picksCount: appState.picksCount,
                speciesEntries: appState.speciesEntries,
                processingFolder: appState.processingFolder,
                processingProgress: appState.processingProgress,
                processingProcessed: appState.processingProcessed,
                processingTotal: appState.processingTotal,
                onAddFolder: { pickAndProcess() },
                onRemoveFolder: { folder in
                    if appState.currentFolder == folder {
                        appState.clearPhotos()
                    }
                    saveFolders()
                },
                onCancelProcessing: { cancelProcessing() },
                onReprocessFolder: { folder in reprocessFolder(folder) },
                onRefreshFolder: { folder in startProcessing(folder: folder) }
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            if appState.isEmpty {
                EmptyStateView { pickAndProcess() }
            } else {
                ContentView(
                    appState: appState,
                    photos: appState.photos,
                    selectedPhotoID: $appState.selectedPhotoID,
                    selectedPhoto: appState.selectedPhoto,
                    onRatePhoto: { id, rating in
                        appState.setRating(ids: [id], rating: rating)
                    },
                    onTogglePick: { id in
                        appState.setPick(ids: [id])
                    },
                    onRejectPhoto: { id in
                        appState.reject(ids: [id])
                    },
                    onUndo: {
                        appState.undoLastAction()
                    },
                    canUndo: appState.canUndo,
                    onExportPicks: {
                        exportPicks()
                    },
                    onExportAllVisible: { photos in
                        exportAllVisible(photos)
                    },
                    onDeletePhoto: { id in
                        appState.deletePhoto(id: id)
                    },
                    onDeleteRejectedPhotos: {
                        appState.deleteRejectedPhotos()
                    },
                    onCorrectSpecies: { id, name in
                        let ids: Set<UUID> = appState.selection.isMulti
                            ? appState.selection.selectedIDs
                            : [id]
                        appState.correctSpecies(ids: ids, commonName: name)
                    },
                    searchSpecies: { [speciesDB] query in
                        guard let speciesDB else { return [] }
                        return await Task.detached(priority: .userInitiated) {
                            speciesDB.search(query: query).map { entry in
                                SpeciesMatch(
                                    scientificName: entry.scientificName,
                                    commonName: entry.englishName,
                                    confidence: 0,
                                    cnName: entry.chineseName.isEmpty ? nil : entry.chineseName,
                                    pinyin: entry.pinyin,
                                    pinyinInitials: entry.pinyinInitials,
                                    thresholdUsed: "manual",
                                    ebirdCode: entry.ebirdCode
                                )
                            }
                        }.value
                    }
                )
            }
        }
        .navigationTitle("")
        .onChange(of: config.speciesSortOrder) { _, newValue in
            appState.speciesSortOrder = newValue
            appState.resortSpeciesEntries()
        }
        .onChange(of: config.appLanguage) { _, _ in
            syncSpeciesDisplay()
            appState.resortSpeciesEntries()
        }
        .onChange(of: appState.sidebarSelection) { _, newValue in
            switch newValue {
            case .folder(let url):
                appState.loadPhotos(for: url, deferSelection: true)
            case .rating, .rejected, .flying, .picks, .species, .burstGroup, .singles:
                appState.applyFilter(autoSelectFirst: false)
            case nil:
                break
            }
        }
        .onAppear {
            appState.speciesSortOrder = config.speciesSortOrder
            syncSpeciesDisplay()
            loadSpeciesDatabase()
            FlushCoordinator.shared.register(owner: appState) { [weak appState] in
                await appState?.flushPendingPersistence()
            }
            if let testFolder = ProcessInfo.processInfo.environment["TEST_FOLDER"] {
                let folder = URL(fileURLWithPath: testFolder)
                Task {
                    await MainActor.run {
                        startProcessing(folder: folder)
                    }
                }
            } else {
                loadSavedFolders()
                if let last = appState.folders.last {
                    appState.sidebarSelection = .folder(last)
                    appState.loadPhotos(for: last)
                    maybeResumeProcessing(folder: last)
                }
            }
        }
        .sheet(isPresented: $isExporting) {
            VStack(spacing: 16) {
                Text(config.localized("Exporting..."))
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
        .alert(config.localized("Export"), isPresented: $showExportComplete) {
            if let dest = exportDestination {
                Button(config.localized("Reveal in Finder")) {
                    NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: dest.path)
                }
            }
            Button(config.localized("OK"), role: .cancel) {}
        } message: {
            Text(exportResultMessage)
        }
    }

    /// Load the bundled species DB once on appear. Keeps the species edit
    /// panel's autocomplete working even if the CoreML pipeline isn't
    /// available (e.g. models haven't been downloaded yet).
    private func loadSpeciesDatabase() {
        guard speciesDB == nil else { return }
        guard let url = SpeciesDatabase.bundledURL() else { return }
        Task {
            let loaded = await Task.detached(priority: .utility) {
                try? SpeciesDatabase(url: url)
            }.value
            guard !Task.isCancelled else { return }
            speciesDB = loaded
        }
    }

    /// Mirror the current config's display-name + locale into AppState so
    /// the species sidebar sorts by whatever the user sees.
    private func syncSpeciesDisplay() {
        let snapshot = config
        appState.speciesDisplayName = { entry in
            if entry.isUnidentified { return entry.name }
            return snapshot.localizedName(en: entry.name, cn: entry.cnName)
        }
        appState.speciesSortLocale = config.appLanguage.locale
    }

    private func saveFolders() {
        let paths = appState.folders.map { $0.path }
        UserDefaults.standard.set(paths, forKey: Self.foldersKey)
    }

    private func loadSavedFolders() {
        guard let paths = UserDefaults.standard.stringArray(forKey: Self.foldersKey) else {
            // Migrate from legacy single-folder key
            if let legacy = UserDefaults.standard.string(forKey: "lastFolderPath"), !legacy.isEmpty {
                restoreFolder(URL(fileURLWithPath: legacy))
            }
            return
        }
        for path in paths {
            restoreFolder(URL(fileURLWithPath: path))
        }
    }

    private func restoreFolder(_ folder: URL) {
        let dbPath = folder.appendingPathComponent(".report.db").path
        guard FileManager.default.fileExists(atPath: dbPath) else { return }
        if !appState.folders.contains(folder) {
            appState.folders.append(folder)
        }
    }

    private func cancelProcessing() {
        processingTask?.cancel()
        processingTask = nil
        appState.processingFolder = nil
        appState.processingProgress = 0
        appState.processingProcessed = 0
        appState.processingTotal = 0
    }

    private func exportAllVisible(_ photos: [Photo]) {
        guard !photos.isEmpty else {
            exportResultMessage = config.localized("No photos in the current view")
            showExportComplete = true
            return
        }
        performExport(photos: photos)
    }

    private func reprocessFolder(_ folder: URL) {
        guard !appState.isProcessing else { return }

        // Clear non-manual photos so pipeline reprocesses them
        if let db = try? ReportDatabase(folderPath: folder) {
            try? db.deleteNonManualPhotos()
        }

        startProcessing(folder: folder)
    }

    private func exportPicks() {
        // Export picks that are also visible in current filter
        let picks = appState.photos.filter { $0.isPick }
        guard !picks.isEmpty else {
            exportResultMessage = config.localized("No picks in the current view")
            showExportComplete = true
            return
        }
        performExport(photos: picks)
    }

    @MainActor
    private func performExport(photos: [Photo]) {
        guard let folder = appState.currentFolder else { return }

        let destination = ExportService.picksDestination(for: folder)
        exportDestination = destination
        exportProgress = 0
        exportTotal = photos.count
        isExporting = true

        Task {
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let result = try await ExportService.export(
                    photos: photos,
                    to: destination,
                    onProgress: { current, total in
                        exportProgress = current
                        exportTotal = total
                    }
                )
                isExporting = false
                exportResultMessage = String(format: config.localized("Exported %lld photos"), result.exportedCount)
                if result.skippedCount > 0 {
                    exportResultMessage += String(format: config.localized(", %lld skipped"), result.skippedCount)
                }
                showExportComplete = true
            } catch {
                isExporting = false
                exportResultMessage = String(format: config.localized("Export failed: %@"), error.localizedDescription)
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
        panel.message = config.localized("Select a folder with bird photos to process")
        panel.prompt = config.localized("Process")

        guard panel.runModal() == .OK, let url = panel.url else { return }
        startProcessing(folder: url)
    }

    private let logger = Logger(subsystem: "com.halfhacked.superpicky", category: "MainView")

    /// Auto-resume if the folder has more files than the DB has rows
    /// (crash-interrupted run or user dropped in new photos).
    private func maybeResumeProcessing(folder: URL) {
        guard !appState.isProcessing, !isTestMode else { return }
        Task.detached(priority: .utility) {
            // Cheap signals first: never-processed folders have no DB —
            // no point walking the drive recursively to find that out.
            let dbPath = folder.appendingPathComponent(".report.db").path
            guard FileManager.default.fileExists(atPath: dbPath) else { return }
            let inDB = (try? ReportDatabase(folderPath: folder).fetchAllFilePaths().count) ?? 0
            guard inDB > 0 else { return }
            let scanned = (try? DirectoryScanner().scan(folder: folder))?.count ?? 0
            guard scanned > inDB else { return }
            await MainActor.run {
                logger.info("Auto-resuming \(folder.lastPathComponent, privacy: .public): \(scanned - inDB) of \(scanned) un-processed")
                startProcessing(folder: folder)
            }
        }
    }

    private func startProcessing(folder: URL) {
        guard !appState.isProcessing else { return }

        let client: InferenceClient
        if isTestMode {
            client = MockInferenceClientForUI()
        } else if let coreml = try? CoreMLInferenceClient.make(modelsDir: modelState.modelsDir) {
            client = coreml
        } else {
            logger.error("CoreML models not available — cannot process folder")
            return
        }

        let pipeline = PipelineCoordinator(inferenceClient: client)

        let ratingConfig = RatingEngine.Config(
            sharpnessThreshold: config.sharpnessThreshold,
            aestheticsThreshold: config.aestheticsThreshold,
            minConfidence: config.minConfidence,
            minSharpness: 100,
            minAesthetics: config.minAesthetics
        )
        let exposureEnabled = config.exposureDetectionEnabled
        let exposureThreshold = config.exposureThreshold
        // Add folder to sidebar immediately and remember it
        if !appState.folders.contains(folder) {
            appState.folders.append(folder)
        }
        saveFolders()
        appState.sidebarSelection = .folder(folder)
        appState.processingFolder = folder
        appState.processingProgress = 0
        appState.processingProcessed = 0
        appState.processingTotal = 0
        // Seed allPhotos from the DB so any already-processed photos (skipped
        // by the pipeline) appear immediately, and so incremental append can
        // update-in-place by ID.
        PreviewSweepCoordinator.shared.stop()
        appState.loadPhotos(for: folder, startPreviewSweep: false)

        processingTask = Task {
            let batcher = PhotoIngestBatcher(appState: appState, pipeline: pipeline)
            await pipeline.process(
                folder: folder,
                ratingConfig: ratingConfig,
                exposureEnabled: exposureEnabled,
                exposureThreshold: exposureThreshold,
                flightDetectionEnabled: config.flightDetectionEnabled,
                burstDetectionEnabled: config.burstDetectionEnabled,
                burstFps: config.burstFps,
                burstMinCount: config.burstMinCount,
                burstHashTolerance: config.burstHashTolerance,
                onPhotoProcessed: { photo in
                    await batcher.enqueue(photo)
                }
            )
            batcher.flush()

            // Run unconditionally — cancelled runs also need the
            // sidebar to reflect the DB state (burst reassignment
            // is deferred to this rebuild).
            await MainActor.run {
                appState.processingFolder = nil
                appState.processingProgress = 0
                appState.processingProcessed = 0
                appState.processingTotal = 0
                appState.loadPhotos(for: folder)
            }
            if !Task.isCancelled, !isTestMode { NSSound.beep() }
        }
    }
}
