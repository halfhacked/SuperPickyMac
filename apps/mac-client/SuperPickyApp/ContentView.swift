import SwiftUI
import AppKit

/// Main content area: preview on top, thumbnail strip at bottom.
struct ContentView: View {
    let photos: [Photo]
    @Binding var selectedPhotoID: UUID?
    let selectedPhoto: Photo?
    var onRatePhoto: ((UUID, Int) -> Void)?
    @State private var showExifPanel = true
    @State private var showFullscreen = false
    @State private var zoomState = ZoomState()
    @State private var previewSize: CGSize = .zero
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
                    onRatePhoto: onRatePhoto
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
            let mouseInWindow = NSApp.keyWindow?.mouseLocationOutsideOfEventStream ?? .zero
            let mouseInView = CGPoint(x: mouseInWindow.x, y: previewSize.height - mouseInWindow.y)
            zoomState.toggleFitActualPixelsAt(
                imagePixelWidth: previewSize.width * 2,
                viewSize: previewSize,
                mouseInView: mouseInView
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
