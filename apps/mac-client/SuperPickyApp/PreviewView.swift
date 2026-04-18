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

/// Full-resolution decodes kept around for instant zoom on recently-viewed
/// photos. Kept separate from the preview cache because each entry is large
/// (~80 MB for a 5616 × 3744 ARW).
private final class FullResCache {
    static let shared = FullResCache()
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 3
        cache.totalCostLimit = 400 * 1024 * 1024  // 400MB
    }

    func get(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    func set(_ key: String, image: NSImage) {
        let pixelsWide = image.representations.first?.pixelsWide ?? Int(image.size.width)
        let pixelsHigh = image.representations.first?.pixelsHigh ?? Int(image.size.height)
        cache.setObject(image, forKey: key as NSString, cost: pixelsWide * pixelsHigh * 4)
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
            if zoomState.scale > 1.0 {
                // Already zoomed — full-res is what the user will see. Serve
                // from cache if possible, otherwise decode now.
                if let full = FullResCache.shared.get(filePath) {
                    image = full
                    isFullRes = true
                } else if let full = await ImageLoader.load(path: filePath, maxPixelSize: nil) {
                    FullResCache.shared.set(filePath, image: full)
                    image = full
                    isFullRes = true
                }
                return
            }
            // Fit-view: show the fast preview. The full-res cache (if any) is
            // reserved for the zoom path — swapping an 80 MB NSImage into the
            // view causes a main-thread redraw that backs up arrow-key nav.
            if let cached = PreviewCache.shared.get(filePath) {
                image = cached
            } else if let loaded = await ImageLoader.load(path: filePath, maxPixelSize: 2000) {
                PreviewCache.shared.set(filePath, image: loaded)
                image = loaded
            }
            // Dwell — after 400 ms of no navigation, quietly warm the full-res
            // cache so a subsequent zoom is instant. The displayed preview is
            // NOT swapped: rebinding SwiftUI's image to an 80 MB decode forces
            // a main-thread redraw that backs up arrow-key handling. The cache
            // hit in the zoom path (below) is what benefits.
            //
            // Task cancellation (filePath changes, view disappears) throws out
            // of the sleep and skips the decode entirely.
            try? await Task.sleep(nanoseconds: 400_000_000)
            if Task.isCancelled { return }
            // Small sources (e.g. 1600 px test JPEGs) — the preview already IS
            // the full image; just promote it into the full-res cache.
            if let sourceW = ImageLoader.pixelWidth(path: filePath), sourceW <= 2000 {
                if let current = image { FullResCache.shared.set(filePath, image: current) }
                return
            }
            if let full = await ImageLoader.load(path: filePath, maxPixelSize: nil) {
                if Task.isCancelled { return }
                FullResCache.shared.set(filePath, image: full)
            }
        }
        .onChange(of: zoomState.scale) { _, newScale in
            // Load full-res when user zooms in
            if newScale > 1.0 && !isFullRes {
                isFullRes = true
                if let cached = FullResCache.shared.get(filePath) {
                    image = cached
                    return
                }
                Task {
                    if let fullRes = await ImageLoader.load(path: filePath, maxPixelSize: nil) {
                        FullResCache.shared.set(filePath, image: fullRes)
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
