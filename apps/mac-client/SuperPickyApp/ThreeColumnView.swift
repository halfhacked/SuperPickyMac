import SwiftUI

@Observable
final class AppState {
    var sidebarSelection: SidebarSelection?
    var selectedPhotoID: UUID?
    var folders: [URL] = []
    var photos: [Photo] = []
    var ratingCounts: [Int: Int] = [:]
    var speciesList: [(name: String, count: Int)] = []

    // Per-folder processing state
    var processingFolder: URL?
    var processingProgress: Double = 0 // 0-1
    var processingFilename: String = ""

    var isProcessing: Bool { processingFolder != nil }

    var selectedPhoto: Photo? {
        guard let id = selectedPhotoID else { return nil }
        return photos.first { $0.id == id }
    }

    var isEmpty: Bool {
        folders.isEmpty || photos.isEmpty
    }

    /// Load photos from the database for the selected folder.
    func loadPhotos(for folder: URL) {
        do {
            let db = try ReportDatabase(folderPath: folder)
            photos = try db.fetchAllPhotos()
            ratingCounts = try db.ratingCounts()

            // Build species list
            var speciesMap: [String: Int] = [:]
            for photo in photos {
                if let name = photo.speciesCommonName ?? photo.speciesScientificName {
                    speciesMap[name, default: 0] += 1
                }
            }
            speciesList = speciesMap.map { (name: $0.key, count: $0.value) }
                .sorted { $0.count > $1.count }

            // Auto-select first photo
            if selectedPhotoID == nil, let first = photos.first {
                selectedPhotoID = first.id
            }
        } catch {
            photos = []
            ratingCounts = [:]
            speciesList = []
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
                speciesList: appState.speciesList,
                processingFolder: appState.processingFolder,
                processingProgress: appState.processingProgress,
                onAddFolder: { pickAndProcess() }
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
            if case .folder(let url) = newValue {
                appState.loadPhotos(for: url)
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
            // Observe pipeline progress
            let progressTask = Task {
                while !Task.isCancelled {
                    await MainActor.run {
                        if pipeline.totalCount > 0 {
                            appState.processingProgress = Double(pipeline.processedCount) / Double(pipeline.totalCount)
                        }
                        appState.processingFilename = pipeline.currentFilename
                    }
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }

            await pipeline.process(
                folder: folder,
                ratingConfig: ratingConfig,
                exposureEnabled: exposureEnabled,
                exposureThreshold: exposureThreshold,
            )

            progressTask.cancel()

            // Processing done — load results on MainActor
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
