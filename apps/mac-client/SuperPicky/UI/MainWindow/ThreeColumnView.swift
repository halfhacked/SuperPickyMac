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
}

struct ThreeColumnView: View {
    @State private var appState = AppState()
    @State private var showProcessingSheet = false
    @State private var columnVisibility = NavigationSplitViewVisibility.all

    var body: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            SourceListView(
                selection: $appState.sidebarSelection,
                folders: appState.folders,
                ratingCounts: appState.ratingCounts,
                speciesList: appState.speciesList
            )
            .navigationSplitViewColumnWidth(min: 180, ideal: 220, max: 300)
        } content: {
            ThumbnailStripView(
                photos: appState.photos,
                selectedPhotoID: $appState.selectedPhotoID
            )
            .navigationSplitViewColumnWidth(min: 100, ideal: 140, max: 200)
        } detail: {
            PreviewView(photo: appState.selectedPhoto)
        }
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showProcessingSheet = true
                } label: {
                    Image(systemName: "plus")
                }
                .help("Process new folder")
                .keyboardShortcut("o", modifiers: .command)
            }
        }
        .sheet(isPresented: $showProcessingSheet) {
            Text("Processing Sheet — coming soon")
                .frame(width: 500, height: 400)
        }
    }
}
