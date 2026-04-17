import SwiftUI
import os

struct MainView: View {
    @Environment(CullingConfig.self) private var config
    let modelState: ModelDownloadState
    @State private var appState = AppState()
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
                    saveFolders()
                },
                onCancelProcessing: { cancelProcessing() },
                onReprocessFolder: { folder in reprocessFolder(folder) },
                onRefreshFolder: { folder in refreshFolder(folder) }
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
                    canUndo: appState.canUndo,
                    onExportPicks: {
                        exportPicks()
                    },
                    onExportAllVisible: { photos in
                        exportAllVisible(photos)
                    },
                    onDeletePhoto: { id in
                        try? appState.deletePhoto(id: id)
                    },
                    onCorrectSpecies: { id, name in
                        appState.correctSpecies(id: id, commonName: name)
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

    /// Scan the folder for new/un-processed photos and kick processing
    /// without clearing the DB. Already-processed photos stay as-is
    /// (skipped by the pipeline); only the gap files get ML'd.
    private func refreshFolder(_ folder: URL) {
        guard !appState.isProcessing else { return }
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

    private let logger = Logger(subsystem: "com.superpicky.mac", category: "MainView")

    /// If the folder has more files on disk than the DB has rows, a
    /// previous run was interrupted (crash, force-quit, or the user
    /// dropped in new photos). Auto-kick processing so the remaining
    /// photos are picked up without a manual click. Scanning the disk
    /// is I/O-bound on an external drive, so do it off the main actor.
    private func maybeResumeProcessing(folder: URL) {
        guard !appState.isProcessing, !isTestMode else { return }
        Task.detached(priority: .utility) {
            let scanned = (try? DirectoryScanner().scan(folder: folder))?.count ?? 0
            let inDB = (try? ReportDatabase(folderPath: folder).fetchAllFilePaths().count) ?? 0
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
        // Seed allPhotos from the DB so any already-processed photos (skipped
        // by the pipeline) appear immediately, and so incremental append can
        // update-in-place by ID.
        appState.loadPhotos(for: folder)

        processingTask = Task {
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
                pickedTopPercentage: config.pickedTopPercentage,
                onPhotoProcessed: { photo in
                    await MainActor.run {
                        if pipeline.totalCount > 0 {
                            appState.processingProgress = Double(pipeline.processedCount) / Double(pipeline.totalCount)
                        }
                        if let photo {
                            appState.appendProcessedPhoto(photo)
                        }
                    }
                }
            )

            // Final reload (picks up picked-flag calculation + any skip-reconciliation burst sweep)
            await MainActor.run {
                appState.processingFolder = nil
                appState.processingProgress = 0
                appState.loadPhotos(for: folder)
            }
            if !isTestMode { NSSound.beep() }
        }
    }
}
