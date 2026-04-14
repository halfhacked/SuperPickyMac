import SwiftUI

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
