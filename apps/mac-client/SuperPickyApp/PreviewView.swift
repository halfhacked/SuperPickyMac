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
        .onChange(of: photo?.id) { _, newID in
            previousPhotoID = newID
        }
    }
}

/// NSCache wrapper keyed by file path. Preview holds many small 2000 px
/// decodes; fullRes holds full-resolution eager-decoded bitmaps to keep
/// zoom-mode navigation instant. Both caches are shared between
/// PreviewView, FullscreenViewer, and the zoom neighbour-prefetcher so
/// back-arrow nav reuses cached frames regardless of which surface
/// decoded them.
///
/// `fullRes` is sized off `ProcessInfo.physicalMemory` so 64+ GB Macs
/// can hold hundreds of full-res bitmaps and treat re-visits within the
/// folder as zero-cost. 16 GB Macs still get the previous 800 MB / 8
/// entry floor.
final class ImageCache {
    static let preview = ImageCache(name: "preview", countLimit: 10, byteLimit: 400 * 1024 * 1024)
    static let fullRes: ImageCache = {
        let budget = computeFullResBudget()
        Logger.imageCache.info(
            "fullRes budget: \(budget.count) entries, \(budget.bytes / (1024 * 1024)) MB (physical=\(ProcessInfo.processInfo.physicalMemory / (1024 * 1024 * 1024)) GB) aggressive=\(PreviewCache.settings.aggressiveCache, privacy: .public)"
        )
        return ImageCache(name: "fullRes", countLimit: budget.count, byteLimit: budget.bytes)
    }()

    /// Roughly an eager-decoded ARW (6000×4000 × 4 bytes/px ≈ 96 MB).
    /// Used to translate the byte budget into an entry count.
    private static let estimatedEntryBytes = 96 * 1024 * 1024

    /// Memory-budget floor (per device) and ceiling. Floor keeps the
    /// 16 GB-Mac experience at least as good as the previous static
    /// 800 MB cap. Ceiling avoids starving other apps on workstation
    /// macs with hundreds of GB of RAM.
    private static let minBytes = 800 * 1024 * 1024
    private static let maxBytes = 32 * 1024 * 1024 * 1024  // 32 GB

    /// Resolve the cache budget. "Aggressive" uses 50% of physical RAM,
    /// "balanced" (default) uses 25%. Both clamp to [minBytes, maxBytes].
    static func computeFullResBudget() -> (count: Int, bytes: Int) {
        let physical = ProcessInfo.processInfo.physicalMemory
        let fraction = PreviewCache.settings.aggressiveCache ? 0.5 : 0.25
        let raw = Int(Double(physical) * fraction)
        let bytes = max(minBytes, min(maxBytes, raw))
        let count = max(8, bytes / estimatedEntryBytes)
        return (count, bytes)
    }

    /// Re-apply the budget at runtime when the Settings toggle flips. Cheap
    /// — NSCache will lazily evict any entries that exceed the new caps.
    /// Also clamp the bookkeeping mirror to the new limits so the Settings
    /// readout doesn't briefly show "200 / 80 entries" after a shrink.
    func resize(countLimit: Int, byteLimit: Int) {
        cache.countLimit = countLimit
        cache.totalCostLimit = byteLimit
        bookkeeping.withLock { state in
            state.count = min(state.count, countLimit)
            state.bytes = min(state.bytes, byteLimit)
        }
        Logger.imageCache.info("resize \(self.name, privacy: .public): \(countLimit) entries, \(byteLimit / (1024 * 1024)) MB")
    }

    let name: String
    private let cache = NSCache<NSString, NSImage>()
    private let delegate: ImageCacheDelegate

    /// Best-effort mirror of NSCache's contents — NSCache doesn't expose
    /// count or total cost, so we maintain them ourselves under a lock.
    /// Used only for diagnostic logging; not relied on for correctness.
    private let bookkeeping = OSAllocatedUnfairLock<(count: Int, bytes: Int)>(initialState: (0, 0))

    init(name: String, countLimit: Int, byteLimit: Int) {
        self.name = name
        self.delegate = ImageCacheDelegate()
        cache.countLimit = countLimit
        cache.totalCostLimit = byteLimit
        cache.delegate = delegate
        delegate.owner = self
    }

    func get(_ key: String) -> NSImage? { cache.object(forKey: key as NSString) }

    func set(_ key: String, image: NSImage) {
        let w = image.representations.first?.pixelsWide ?? Int(image.size.width)
        let h = image.representations.first?.pixelsHigh ?? Int(image.size.height)
        let cost = w * h * 4
        cache.setObject(image, forKey: key as NSString, cost: cost)
        // NSCache's willEvictObject delegate is best-effort — under count
        // overflow it sometimes batch-evicts without notifying. Cap our
        // mirror at the configured limits so bookkeeping can't run away;
        // the eviction callback brings it down further when it fires.
        bookkeeping.withLock { state in
            state.count = min(state.count + 1, self.cache.countLimit)
            state.bytes = min(state.bytes + cost, self.cache.totalCostLimit)
        }
        Logger.imageCache.info(
            "\(self.name, privacy: .public) set \((key as NSString).lastPathComponent, privacy: .public) cost=\(cost / (1024 * 1024))MB approx_total=\(self.approximateBytes() / (1024 * 1024))MB count=\(self.approximateCount())"
        )
    }

    func approximateCount() -> Int { bookkeeping.withLock { $0.count } }
    func approximateBytes() -> Int { bookkeeping.withLock { $0.bytes } }

    fileprivate func noteEviction(_ image: NSImage) {
        let w = image.representations.first?.pixelsWide ?? Int(image.size.width)
        let h = image.representations.first?.pixelsHigh ?? Int(image.size.height)
        let cost = w * h * 4
        bookkeeping.withLock { state in
            state.count = max(0, state.count - 1)
            state.bytes = max(0, state.bytes - cost)
        }
        Logger.imageCache.info(
            "\(self.name, privacy: .public) evict cost=\(cost / (1024 * 1024))MB approx_total=\(self.approximateBytes() / (1024 * 1024))MB count=\(self.approximateCount())"
        )
    }
}

/// Per-instance NSCache delegate so each `ImageCache` knows when its own
/// cache evicts an entry and can update its bookkeeping.
private final class ImageCacheDelegate: NSObject, NSCacheDelegate {
    weak var owner: ImageCache?

    func cache(_ cache: NSCache<AnyObject, AnyObject>, willEvictObject obj: Any) {
        guard let image = obj as? NSImage else { return }
        owner?.noteEviction(image)
    }
}

extension Logger {
    fileprivate static let imageCache = Logger(subsystem: "com.halfhacked.superpicky", category: "ImageCache")
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
                if let full = await loadFullRes(filePath) {
                    guard !Task.isCancelled else { return }
                    image = full
                    isFullRes = true
                }
                return
            }
            if let cached = ImageCache.preview.get(filePath) {
                image = cached
            } else if let loaded = await ImageLoader.load(path: filePath, maxPixelSize: 2000) {
                guard !Task.isCancelled else { return }
                ImageCache.preview.set(filePath, image: loaded)
                image = loaded
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
            guard newScale > 1.0, !isFullRes else { return }
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
                    isFullRes = false  // allow retry on next zoom
                }
            }
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
