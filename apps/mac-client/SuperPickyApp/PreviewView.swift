import SwiftUI
import os

struct PreviewView: View {
    let photo: Photo?
    @Bindable var zoomState: ZoomState
    var brightnessAdjustment: Double = 0
    @Binding var mouseInView: CGPoint
    @Binding var viewSize: CGSize
    var appState: AppState? = nil
    var onCorrectSpecies: ((UUID, String) -> Void)?
    @Environment(CullingConfig.self) private var config

    var body: some View {
        VStack(spacing: 0) {
            if let photo {
                AsyncPreviewImage(filePath: photo.filePath, zoomState: zoomState, brightnessAdjustment: brightnessAdjustment)
                    .accessibilityIdentifier("PhotoPreview")
                    .onContinuousHover { phase in
                        if case .active(let loc) = phase { mouseInView = loc }
                    }
                    .background(GeometryReader { geo in
                        Color.clear.onAppear { viewSize = geo.size }
                            .onChange(of: geo.size) { _, s in viewSize = s }
                    })
                InfoBarView(photo: photo, appState: appState, onCorrectSpecies: { name in
                    onCorrectSpecies?(photo.id, name)
                })
            } else {
                VStack(spacing: 12) {
                    Image(systemName: "bird")
                        .font(.system(size: 48, weight: .ultraLight))
                        .foregroundStyle(.quaternary)
                    Text(config.localized("Select a photo to preview"))
                        .font(.title3)
                        .foregroundStyle(.tertiary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }
}

/// Loads a full-size preview image asynchronously.
struct AsyncPreviewImage: View {
    let filePath: String
    @Bindable var zoomState: ZoomState
    var brightnessAdjustment: Double = 0
    @State private var image: NSImage?
    @State private var isFullRes = false

    /// Replace the displayed preview-tier image with a full-res decode in
    /// place. Used both when the user zooms in and when the user dwells
    /// on a photo while already at zoom > 1.0.
    private func upgradeToFullRes() {
        if isFullRes { return }
        isFullRes = true
        if let cached = ImageCache.fullRes.get(filePath) {
            image = cached
            return
        }
        let pinnedPath = filePath
        Task {
            if let full = await loadFullRes(pinnedPath) {
                guard !Task.isCancelled, filePath == pinnedPath else { return }
                image = full
            } else if filePath == pinnedPath {
                isFullRes = false
            }
        }
    }

    var body: some View {
        ZStack {
            Color(nsColor: .controlBackgroundColor)
            if let image {
                ZoomableImageView(image: image, zoomState: zoomState, brightnessAdjustment: brightnessAdjustment)
            } else {
                ProgressView()
            }
        }
        .task(id: filePath) {
            isFullRes = false
            let cachedFullRes = ImageCache.fullRes.get(filePath)
            let cachedPreview = ImageCache.preview.get(filePath)
            let action = decidePrimaryLoad(
                state: NavigationStateMonitor.shared.state,
                zoomScale: zoomState.scale,
                hasFullRes: cachedFullRes != nil,
                hasPreview: cachedPreview != nil
            )
            switch action {
            case .useCachedFullRes:
                image = cachedFullRes
                isFullRes = true
                return
            case .loadFullResDirect:
                if let full = await loadFullRes(filePath) {
                    guard !Task.isCancelled else { return }
                    image = full
                    isFullRes = true
                }
                return
            case .useCachedPreview:
                image = cachedPreview
            case .loadPreview:
                if let loaded = await ImageLoader.load(path: filePath, maxPixelSize: 2000) {
                    guard !Task.isCancelled else { return }
                    ImageCache.preview.set(filePath, image: loaded)
                    image = loaded
                }
            }
            // Dwell-preload: rebinding an 80 MB NSImage while at fit scale
            // forces a main-thread redraw that stalls arrow-key handling, so
            // we only warm the full-res cache — zoom picks it up later.
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            if ImageCache.fullRes.get(filePath) != nil { return }
            if let size = ImageLoader.pixelSize(path: filePath), max(size.width, size.height) <= 2000 {
                if let current = image { ImageCache.fullRes.set(filePath, image: current) }
                return
            }
            if let full = await ImageLoader.load(path: filePath, maxPixelSize: nil) {
                if Task.isCancelled { return }
                ImageCache.fullRes.set(filePath, image: full)
            }
        }
        .onChange(of: zoomState.scale) { _, newScale in
            guard newScale > 1.0 else { return }
            upgradeToFullRes()
        }
        .onChange(of: NavigationStateMonitor.shared.state) { _, newState in
            // After a skim ends in zoom mode, swap the soft preview-tier
            // image we displayed during skim for a full-res decode.
            guard newState == .dwell, zoomState.scale > 1.0 else { return }
            upgradeToFullRes()
        }
    }

    private func loadFullRes(_ path: String) async -> NSImage? {
        if let cached = ImageCache.fullRes.get(path) { return cached }
        guard let full = await ImageLoader.load(path: path, maxPixelSize: nil) else { return nil }
        ImageCache.fullRes.set(path, image: full)
        return full
    }
}

struct InfoBarView: View {
    let photo: Photo
    @Environment(CullingConfig.self) private var config
    /// Optional appState — when set, inline rename applies to the current
    /// selection (1 or N photos) and the species label gets a "N selected"
    /// suffix when multi.
    var appState: AppState? = nil
    var onCorrectSpecies: ((String) -> Void)?

    @State private var isEditingSpecies = false
    @State private var editingSpeciesName = ""

    private var isMulti: Bool { (appState?.selection.isMulti) ?? false }
    private var selectionCount: Int { appState?.selection.count ?? 1 }

    var body: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                StarRatingView(rating: photo.starRating)
                    .accessibilityElement(children: .ignore)
                    .accessibilityIdentifier("InfoBarRating")
                    .accessibilityLabel(config.localized("Star rating"))
                    .accessibilityValue("\(photo.starRating)")
                if photo.isManualRating {
                    Image(systemName: "pencil")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .accessibilityIdentifier("ManualRatingIndicator")
                }
            }

            if let sharpness = photo.sharpnessScore {
                Label {
                    Text("\(config.localized("Sharp")): \(Int(sharpness))")
                } icon: { Image(systemName: "scope") }
                    .font(.caption)
            }

            if let aesthetics = photo.aestheticsScore {
                Label {
                    Text("\(config.localized("Aesth")): \(String(format: "%.1f", aesthetics))")
                } icon: { Image(systemName: "sparkles") }
                    .font(.caption)
            }

            if photo.isFlying {
                Label { Text(config.localized("Flying")) } icon: { Image(systemName: "bird") }
                    .font(.caption)
                    .foregroundStyle(.green)
            }

            if isEditingSpecies {
                HStack(spacing: 4) {
                    Image(systemName: "bird.fill")
                        .font(.caption)
                    TextField(config.localized("Species name"), text: $editingSpeciesName)
                        .font(.caption)
                        .textFieldStyle(.plain)
                        .frame(width: 150)
                        .accessibilityIdentifier("SpeciesEditField")
                        .onSubmit {
                            commitSpeciesEdit()
                        }
                        .onExitCommand {
                            isEditingSpecies = false
                        }
                }
            } else if let species = photo.speciesScientificName {
                Label {
                    Text(config.localizedName(en: photo.speciesCommonName ?? species, cn: photo.speciesCnName))
                    if let conf = photo.speciesConfidence {
                        Text("\(Int(conf * 100))%")
                            .foregroundStyle(.secondary)
                    }
                    let extras = max(0, photo.assignedSpecies.count - 1)
                    if extras > 0 {
                        Text("+\(extras)")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 5)
                            .padding(.vertical, 1)
                            .background(.quaternary)
                            .clipShape(Capsule())
                            .accessibilityIdentifier("InfoBarExtraSpeciesCount")
                    }
                    if isMulti {
                        Text(String(format: config.localized("(%lld selected)"), selectionCount))
                            .font(.caption2)
                            .foregroundStyle(.tint)
                    }
                } icon: {
                    Image(systemName: "bird.fill")
                }
                .font(.caption)
                .onTapGesture(count: 2) {
                    editingSpeciesName = photo.speciesCommonName ?? species
                    isEditingSpecies = true
                }
                .help(config.localized("Double-click to correct species name"))
            }

            Spacer()

            Text(photo.filename)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(.bar)
        .accessibilityIdentifier("InfoBar")
        .onChange(of: photo.id) {
            isEditingSpecies = false
        }
    }

    private func commitSpeciesEdit() {
        onCorrectSpecies?(editingSpeciesName)
        isEditingSpecies = false
    }
}
