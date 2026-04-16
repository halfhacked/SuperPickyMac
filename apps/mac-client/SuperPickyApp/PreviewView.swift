import SwiftUI

struct PreviewView: View {
    let photo: Photo?
    @Bindable var zoomState: ZoomState
    var brightnessAdjustment: Double = 0
    @Binding var mouseInView: CGPoint
    @Binding var viewSize: CGSize
    var onCorrectSpecies: ((UUID, String) -> Void)?
    @Environment(CullingConfig.self) private var config
    @State private var previousPhotoID: UUID?

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
                InfoBarView(photo: photo, onCorrectSpecies: { name in
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
        .onChange(of: photo?.id) { _, newID in
            previousPhotoID = newID
        }
    }
}

private final class PreviewCache {
    static let shared = PreviewCache()
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 5          // preview images are large — keep very few
        cache.totalCostLimit = 200 * 1024 * 1024  // 200MB
    }

    func get(_ key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ key: String, image: NSImage) {
        let pixelsWide = image.representations.first?.pixelsWide ?? Int(image.size.width)
        let pixelsHigh = image.representations.first?.pixelsHigh ?? Int(image.size.height)
        let cost = pixelsWide * pixelsHigh * 4
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}

/// Loads a full-size preview image asynchronously.
struct AsyncPreviewImage: View {
    let filePath: String
    @Bindable var zoomState: ZoomState
    var brightnessAdjustment: Double = 0
    @State private var image: NSImage?
    @State private var isFullRes = false

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
            // Check cache first (preview resolution only — not full-res)
            if let cached = PreviewCache.shared.get(filePath) {
                image = cached
                return
            }
            if zoomState.scale > 1.0 {
                // Already zoomed in — load full-res directly (don't cache)
                isFullRes = true
                image = await ImageLoader.load(path: filePath, maxPixelSize: nil)
            } else {
                if let loaded = await ImageLoader.load(path: filePath, maxPixelSize: 2000) {
                    PreviewCache.shared.set(filePath, image: loaded)
                    image = loaded
                }
            }
        }
        .onChange(of: zoomState.scale) { _, newScale in
            // Load full-res when user zooms in
            if newScale > 1.0 && !isFullRes {
                isFullRes = true
                Task {
                    if let fullRes = await ImageLoader.load(path: filePath, maxPixelSize: nil) {
                        image = fullRes
                    }
                }
            }
        }
    }
}

struct InfoBarView: View {
    let photo: Photo
    @Environment(CullingConfig.self) private var config
    var onCorrectSpecies: ((String) -> Void)?

    @State private var isEditingSpecies = false
    @State private var editingSpeciesName = ""

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
