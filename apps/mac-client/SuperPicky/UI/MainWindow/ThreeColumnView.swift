import SwiftUI

@Observable
final class AppState {
    var sidebarSelection: SidebarSelection?
    var selectedPhotoID: UUID?
    var folders: [URL] = []
    var photos: [Photo] = []
    var ratingCounts: [Int: Int] = [:]
    var speciesList: [(name: String, count: Int)] = []
    var isProcessing = false

    var selectedPhoto: Photo? {
        guard let id = selectedPhotoID else { return nil }
        return photos.first { $0.id == id }
    }

    var isEmpty: Bool {
        folders.isEmpty || photos.isEmpty
    }
}

struct MainView: View {
    @State private var appState = AppState()
    @State private var showProcessingSheet = false

    var body: some View {
        NavigationSplitView {
            SourceListView(
                selection: $appState.sidebarSelection,
                folders: $appState.folders,
                ratingCounts: appState.ratingCounts,
                speciesList: appState.speciesList,
                onAddFolder: { showProcessingSheet = true }
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } detail: {
            if appState.isEmpty {
                EmptyStateView { showProcessingSheet = true }
            } else {
                ContentView(
                    photos: appState.photos,
                    selectedPhotoID: $appState.selectedPhotoID,
                    selectedPhoto: appState.selectedPhoto
                )
            }
        }
        .navigationTitle("")
        .sheet(isPresented: $showProcessingSheet) {
            ProcessingSheet(prefilledFolder: nil) { completedFolder in
                if !appState.folders.contains(completedFolder) {
                    appState.folders.append(completedFolder)
                }
                appState.sidebarSelection = .folder(completedFolder)
            }
        }
        .onAppear {
            if ProcessInfo.processInfo.environment["TEST_FOLDER"] != nil {
                showProcessingSheet = true
            }
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
            // Preview area (top, takes most space)
            PreviewView(photo: selectedPhoto)
                .frame(minHeight: 300)

            // Horizontal thumbnail strip (bottom)
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
