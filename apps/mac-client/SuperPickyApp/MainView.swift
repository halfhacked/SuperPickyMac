import SwiftUI

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
                onReprocessFolder: { folder in reprocessFolder(folder) }
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
                    onExportAllVisible: {
                        exportAllVisible()
                    },
                    onDeletePhoto: { id in
                        try? appState.deletePhoto(id: id)
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
            } else {
                loadSavedFolders()
                if let last = appState.folders.last {
                    appState.sidebarSelection = .folder(last)
                    appState.loadPhotos(for: last)
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

    private func exportAllVisible() {
        guard let folder = appState.currentFolder else { return }
        let visible = appState.photos
        guard !visible.isEmpty else {
            exportResultMessage = "No photos in the current view"
            showExportComplete = true
            return
        }

        let destination = ExportService.picksDestination(for: folder)
        exportDestination = destination
        exportProgress = 0
        exportTotal = visible.count
        isExporting = true

        Task {
            do {
                try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
                let result = try await ExportService.export(
                    photos: visible,
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

    private func reprocessFolder(_ folder: URL) {
        guard !appState.isProcessing else { return }
        guard isTestMode || processManager.isReady else { return }

        // Clear non-manual photos so pipeline reprocesses them
        if let db = try? ReportDatabase(folderPath: folder) {
            try? db.deleteNonManualPhotos()
        }

        startProcessing(folder: folder)
    }

    private func exportPicks() {
        guard let folder = appState.currentFolder else { return }
        // Export picks that are also visible in current filter
        let picks = appState.photos.filter { $0.isPick }
        guard !picks.isEmpty else {
            exportResultMessage = "No picks in the current view"
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
        saveFolders()
        appState.sidebarSelection = .folder(folder)
        appState.processingFolder = folder
        appState.processingProgress = 0

        processingTask = Task {
            await pipeline.process(
                folder: folder,
                ratingConfig: ratingConfig,
                exposureEnabled: exposureEnabled,
                exposureThreshold: exposureThreshold,
                burstDetectionEnabled: config.burstDetectionEnabled,
                onPhotoProcessed: {
                    await MainActor.run {
                        if pipeline.totalCount > 0 {
                            appState.processingProgress = Double(pipeline.processedCount) / Double(pipeline.totalCount)
                        }
                        appState.processingFilename = pipeline.currentFilename
                        // Reload UI every 5 photos to avoid jarring per-photo re-renders
                        // Skip hierarchy rebuild during incremental updates (perf: avoids O(n²))
                        if pipeline.processedCount % 5 == 0 {
                            appState.loadPhotos(for: folder, skipHierarchy: true)
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
