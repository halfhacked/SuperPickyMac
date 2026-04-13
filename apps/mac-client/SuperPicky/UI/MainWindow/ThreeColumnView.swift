import SwiftUI

@Observable
final class AppState {
    var sidebarSelection: SidebarSelection?
    var selectedPhotoID: UUID?
    var folders: [URL] = []
    var photos: [Photo] = []
    var ratingCounts: [Int: Int] = [:]
    var speciesList: [(name: String, count: Int)] = []

    var selectedPhoto: Photo? {
        guard let id = selectedPhotoID else { return nil }
        return photos.first { $0.id == id }
    }

    var isEmpty: Bool {
        folders.isEmpty || photos.isEmpty
    }
}

struct MainView: View {
    @Environment(CullingConfig.self) private var config
    @Environment(ProcessManager.self) private var processManager
    @State private var appState = AppState()
    @State private var showProgressSheet = false
    @State private var pipeline: PipelineCoordinator?
    @State private var processingTask: Task<Void, Never>?
    @State private var processingFolderName = ""

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
        .sheet(isPresented: $showProgressSheet) {
            if let pipeline {
                ProcessingSheet(
                    pipeline: pipeline,
                    folderName: processingFolderName,
                    onCancel: { processingTask?.cancel() },
                    onDone: {}
                )
            }
        }
        .onAppear {
            if let testFolder = ProcessInfo.processInfo.environment["TEST_FOLDER"] {
                let url = URL(fileURLWithPath: testFolder)
                startProcessing(folder: url)
            }
        }
    }

    private func pickAndProcess() {
        // In test mode, use TEST_FOLDER env var
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

        let client: InferenceClient = isTestMode
            ? MockInferenceClientForUI()
            : HTTPInferenceClient(port: processManager.port)

        let coord = PipelineCoordinator(inferenceClient: client)
        pipeline = coord
        processingFolderName = folder.lastPathComponent

        let ratingConfig = RatingEngine.Config(
            sharpnessThreshold: config.sharpnessThreshold,
            aestheticsThreshold: config.aestheticsThreshold
        )
        let exposureEnabled = config.exposureDetectionEnabled
        let exposureThreshold = config.exposureThreshold
        let autoOrganize = config.autoOrganize

        showProgressSheet = true

        processingTask = Task {
            await coord.process(
                folder: folder,
                ratingConfig: ratingConfig,
                exposureEnabled: exposureEnabled,
                exposureThreshold: exposureThreshold,
                autoOrganize: autoOrganize
            )
            if !appState.folders.contains(folder) {
                appState.folders.append(folder)
            }
            appState.sidebarSelection = .folder(folder)
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
