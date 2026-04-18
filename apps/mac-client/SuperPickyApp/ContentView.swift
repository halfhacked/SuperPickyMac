import SwiftUI

/// Main content area: preview on top, thumbnail strip at bottom.
struct ContentView: View {
    private enum SortOrder: String, CaseIterable {
        case filename = "Filename"
        case captureDate = "Date"
        case rating = "Rating"
        case sharpness = "Sharpness"
        case aesthetics = "Aesthetics"
    }

    let photos: [Photo]
    @Binding var selectedPhotoID: UUID?
    let selectedPhoto: Photo?
    var onRatePhoto: ((UUID, Int) -> Void)?
    var onTogglePick: ((UUID) -> Void)?
    var onRejectPhoto: ((UUID) -> Void)?
    var onUndo: (() -> Void)?
    var canUndo: Bool = false
    var onExportPicks: (() -> Void)?
    var onExportAllVisible: (([Photo]) -> Void)?
    var onDeletePhoto: ((UUID) -> Void)?
    var onCorrectSpecies: ((UUID, String) -> Void)?
    var onAssignedSpeciesChanged: ((UUID, [SpeciesMatch]) -> Void)?
    var searchSpecies: ((String) -> [SpeciesMatch])?
    @Environment(CullingConfig.self) private var config
    @State private var minimumStars: Int = 0
    @State private var topBurstOnly: Bool = false
    @State private var pickedOnly: Bool = false
    @State private var sortOrder: SortOrder = .filename
    @State private var sortAscending: Bool = true
    @State private var showExifPanel = true
    @State private var showSpeciesEditPanel = false
    @State private var showFullscreen = false
    @State private var zoomState = ZoomState()
    @State private var fullscreenZoomState = ZoomState()
    @State private var previewSize: CGSize = .zero
    @State private var mouseInPreview: CGPoint = .zero
    @State private var brightnessAdj: Double = 0
    @State private var showCompare = false
    @State private var showNoPhotosAlert = false
    @State private var showDeleteConfirm = false
    @State private var pendingDeleteID: UUID?
    @State private var showKeyboardHelp = false
    @State private var showThresholdCalibrator = false

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

        switch sortOrder {
        case .filename:
            result.sort { sortAscending ? $0.filename < $1.filename : $0.filename > $1.filename }
        case .captureDate:
            result.sort { sortAscending ? $0.dateCreated < $1.dateCreated : $0.dateCreated > $1.dateCreated }
        case .rating:
            result.sort { sortAscending ? $0.starRating < $1.starRating : $0.starRating > $1.starRating }
        case .sharpness:
            let s: (Photo) -> Float = { $0.sharpnessScore ?? 0 }
            result.sort { sortAscending ? s($0) < s($1) : s($0) > s($1) }
        case .aesthetics:
            let a: (Photo) -> Float = { $0.aestheticsScore ?? 0 }
            result.sort { sortAscending ? a($0) < a($1) : a($0) > a($1) }
        }
        return result
    }

    var body: some View {
        VSplitView {
            ZStack(alignment: .topTrailing) {
                PreviewView(photo: selectedPhoto, zoomState: zoomState,
                            brightnessAdjustment: brightnessAdj,
                            mouseInView: $mouseInPreview, viewSize: $previewSize,
                            onCorrectSpecies: onCorrectSpecies)

                HStack(alignment: .top, spacing: 0) {
                    Spacer(minLength: 0)
                    if showSpeciesEditPanel, let photo = selectedPhoto {
                        SpeciesEditPanelView(
                            photo: photo,
                            onAssignedChanged: { species in
                                onAssignedSpeciesChanged?(photo.id, species)
                            },
                            searchSpecies: searchSpecies ?? { _ in [] }
                        )
                        .transition(.move(edge: .trailing))
                    }
                    if showExifPanel, let photo = selectedPhoto {
                        ExifPanelView(photo: photo)
                            .transition(.move(edge: .trailing))
                    }
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
                    .help(minimumStars > 0 ? config.localized("Rating ≥ %lld (⌘0 to reset)").replacingOccurrences(of: "%lld", with: "\(minimumStars)") : config.localized("Filter by minimum rating (⌘1–5)"))

                    Divider().frame(height: 12)

                    Button {
                        topBurstOnly.toggle()
                    } label: {
                        Image(systemName: topBurstOnly ? "crown.fill" : "crown")
                            .font(.system(size: 10))
                            .foregroundStyle(topBurstOnly ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(topBurstOnly ? config.localized("Showing burst best only — click to show all") : config.localized("Show only the best photo from each burst"))
                    .accessibilityIdentifier("TopBurstFilter")

                    Button {
                        pickedOnly.toggle()
                    } label: {
                        Image(systemName: pickedOnly ? "flag.fill" : "flag")
                            .font(.system(size: 10))
                            .foregroundStyle(pickedOnly ? .primary : .secondary)
                    }
                    .buttonStyle(.plain)
                    .help(pickedOnly ? config.localized("Showing picks only — click to show all") : config.localized("Show only flagged photos (P to pick)"))
                    .accessibilityIdentifier("PickedFilter")

                    Divider().frame(height: 12)

                    Menu {
                        ForEach(SortOrder.allCases, id: \.self) { order in
                            Button {
                                if sortOrder == order {
                                    sortAscending.toggle()
                                } else {
                                    sortOrder = order
                                    sortAscending = (order == .filename || order == .captureDate)
                                }
                            } label: {
                                HStack {
                                    Text(order.rawValue)
                                    if sortOrder == order {
                                        Image(systemName: sortAscending ? "chevron.up" : "chevron.down")
                                    }
                                }
                            }
                        }
                    } label: {
                        Image(systemName: "arrow.up.arrow.down")
                            .font(.system(size: 10))
                            .foregroundStyle(sortOrder == .filename && sortAscending ? .secondary : .primary)
                    }
                    .menuStyle(.borderlessButton)
                    .fixedSize()
                    .help(config.localized("Sort photos"))
                    .accessibilityIdentifier("SortMenu")

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
            if showKeyboardHelp {
                KeyboardHelpView(isPresented: $showKeyboardHelp)
            }
        }
        .alert(config.localized("Delete Photo?"), isPresented: $showDeleteConfirm) {
            Button(config.localized("Delete"), role: .destructive) {
                if let id = pendingDeleteID {
                    navigatePhoto(direction: 1, fallbackToPrevious: true)
                    onDeletePhoto?(id)
                }
                pendingDeleteID = nil
            }
            Button(config.localized("Cancel"), role: .cancel) { pendingDeleteID = nil }
        } message: {
            if let id = pendingDeleteID, let photo = photos.first(where: { $0.id == id }) {
                Text(config.localized("Move to Trash?"))
            } else {
                Text(config.localized("Move to Trash?"))
            }
        }
        .toolbar {
            ToolbarItem(placement: .automatic) {
                Menu {
                    Button {
                        onExportPicks?()
                    } label: {
                        Label(config.localized("Export Picks"), systemImage: "flag.fill")
                    }
                    Button {
                        onExportAllVisible?(filteredPhotos)
                    } label: {
                        Label(config.localized("Export All Visible"), systemImage: "square.and.arrow.up")
                    }
                } label: {
                    Label(config.localized("Export"), systemImage: "square.and.arrow.up")
                }
                .accessibilityIdentifier("ExportMenu")
                .help(config.localized("Export photos (⌘E for picks)"))
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    showThresholdCalibrator.toggle()
                } label: {
                    Image(systemName: "slider.horizontal.3")
                }
                .popover(isPresented: $showThresholdCalibrator, arrowEdge: .top) {
                    ThresholdCalibratorView(photo: selectedPhoto)
                        .environment(config)
                }
                .accessibilityIdentifier("ThresholdCalibratorButton")
                .help(config.localized("Calibrate thresholds against this photo"))
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
                .help(config.localized("Toggle EXIF Info (I)"))
            }
            ToolbarItem(placement: .automatic) {
                Button {
                    withAnimation(.easeInOut(duration: 0.2)) {
                        showSpeciesEditPanel.toggle()
                    }
                } label: {
                    Image(systemName: showSpeciesEditPanel ? "bird.fill" : "bird")
                }
                .accessibilityIdentifier("SpeciesEditToggle")
                .help(config.localized("Edit species (S)"))
            }
        }
        .alert(config.localized("No Photos"), isPresented: $showNoPhotosAlert) {
            Button(config.localized("OK"), role: .cancel) {}
        } message: {
            Text(config.localized("No photos match the current filter"))
        }
        .onChange(of: selectedPhotoID) { _, _ in
            brightnessAdj = 0
        }
    }

    private func handleKey(_ key: KeyboardMonitor.KeyEvent) -> Bool {
        // Dismiss keyboard help on any key
        if showKeyboardHelp {
            showKeyboardHelp = false
            return true
        }

        // Arrow keys navigate photos
        if key.isLeftArrow { navigatePhoto(direction: -1); return true }
        if key.isRightArrow { navigatePhoto(direction: 1); return true }

        // Escape exits fullscreen
        if key.isEscape && showFullscreen { showFullscreen = false; return true }

        // Cmd+Z: undo
        if key.modifiers.contains(.command), key.characters == "z" {
            if canUndo { onUndo?() }
            return canUndo  // only consume the key event if we actually undid something
        }

        // Cmd+E: export picks. The matching Button lives inside the toolbar
        // Menu (for mouse-driven access via the menu item), but SwiftUI does
        // not reliably register `.keyboardShortcut` on a Menu-nested Button
        // when the menu is closed — so the canonical app-wide NSEvent
        // monitor is the reliable path.
        if key.modifiers.contains(.command), key.characters == "e" {
            onExportPicks?()
            return onExportPicks != nil
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
        case "s":
            withAnimation(.easeInOut(duration: 0.2)) { showSpeciesEditPanel.toggle() }
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
            let imagePixelWidth = ImageLoader.pixelSize(path: photo.filePath)?.width ?? previewSize.width * 2

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
        case "?":
            showKeyboardHelp = true
            return true
        default: break
        }

        // Delete/Backspace key (keyCode 51)
        if key.keyCode == 51 {
            guard let id = selectedPhoto?.id else { return false }
            pendingDeleteID = id
            showDeleteConfirm = true
            return true
        }

        return false
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
    @Environment(CullingConfig.self) private var config

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "folder.badge.plus")
                .font(.system(size: 56, weight: .ultraLight))
                .foregroundStyle(.secondary)

            Text(config.localized("Add a folder to get started"))
                .font(.title3)
                .foregroundStyle(.secondary)

            Text(config.localized("Process bird photos with AI to rate and organize them"))
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            Button {
                onSelectFolder()
            } label: {
                Label(config.localized("Select Folder"), systemImage: "folder")
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
