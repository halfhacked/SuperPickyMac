import SwiftUI
import AppKit

struct ThumbnailStripView: View {
    let photos: [Photo]
    let selection: PhotoSelection

    var body: some View {
        let selectedBurstGroupID: UUID? = {
            guard let id = selection.activeID else { return nil }
            return photos.first(where: { $0.id == id })?.burstGroupID
        }()
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 4) {
                    ForEach(photos) { photo in
                        ThumbnailCell(
                            photo: photo,
                            isActive: photo.id == selection.activeID,
                            isSelected: selection.contains(photo.id),
                            isDimmed: ThumbnailCell.shouldDim(
                                photoBurstGroupID: photo.burstGroupID,
                                selectedBurstGroupID: selectedBurstGroupID
                            )
                        )
                        .id(photo.id)
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            }
            .background(ScrollWheelRedirector())
            .background(MouseClickRedirector { pointInWindow, modifiers in
                handleClick(pointInWindow: pointInWindow, modifiers: modifiers)
            })
            .background(.bar)
            .onChange(of: selection.activeID) { _, newValue in
                if let id = newValue {
                    withAnimation {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }

    /// Hit-test the click point against thumbnail accessibility-identified
    /// NSViews. Returns true if a thumbnail was hit (and a selection
    /// mutation happened); the caller consumes the event.
    private func handleClick(pointInWindow: NSPoint, modifiers: NSEvent.ModifierFlags) -> Bool {
        guard let window = NSApp.keyWindow else { return false }
        guard let view = window.contentView?.hitTest(pointInWindow) else { return false }
        guard let id = ThumbnailCell.findThumbnailIdentifier(from: view) else { return false }
        guard let photo = photos.first(where: { ThumbnailCell.accessibilityID(for: $0) == id }) else {
            return false
        }
        if modifiers.contains(.shift) {
            selection.shiftClick(photo.id, photos: photos)
        } else if modifiers.contains(.command) {
            selection.cmdClick(photo.id, photos: photos)
        } else {
            selection.click(photo.id, photos: photos)
        }
        return true
    }
}

struct ThumbnailCell: View {
    let photo: Photo
    let isActive: Bool
    let isSelected: Bool
    let isDimmed: Bool

    static let accessibilityIDPrefix = "Thumbnail_"

    static func accessibilityID(for photo: Photo) -> String {
        accessibilityIDPrefix + photo.filename
    }

    static func shouldDim(photoBurstGroupID: UUID?, selectedBurstGroupID: UUID?) -> Bool {
        guard let selected = selectedBurstGroupID else { return false }
        return photoBurstGroupID != selected
    }

    /// Walk an NSView ancestry chain looking for a SwiftUI-exposed
    /// accessibility identifier prefixed with `accessibilityIDPrefix`.
    static func findThumbnailIdentifier(from view: NSView) -> String? {
        var current: NSView? = view
        while let v = current {
            if let id = v.accessibilityIdentifier(),
               id.hasPrefix(accessibilityIDPrefix) {
                return id
            }
            current = v.superview
        }
        return nil
    }

    private var borderColor: Color {
        if isActive { return .accentColor }
        if isSelected { return .accentColor.opacity(0.5) }
        if photo.isPick { return .orange.opacity(0.6) }
        return .clear
    }

    private var a11ySelectionValue: String {
        if isActive { return "active" }
        if isSelected { return "selected" }
        return "none"
    }

    var body: some View {
        ZStack {
            AsyncThumbnailImage(filePath: photo.filePath)
                .aspectRatio(3/2, contentMode: .fit)
                .clipped()

            // Flag top-left
            if photo.isPick {
                Image(systemName: "flag.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.orange)
                    .padding(3)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 2))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .padding(2)
                    .transition(.opacity)
                    .accessibilityIdentifier("PickFlag_\(photo.filename)")
            }

            // Burst best bottom-right
            if photo.isBurstBest {
                Image(systemName: "crown.fill")
                    .font(.system(size: 8))
                    .foregroundStyle(.yellow)
                    .padding(3)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 2))
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
                    .padding(2)
            }

            // Stars bottom-left
            StarRatingView(rating: photo.starRating)
                .padding(2)
                .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 2))
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomLeading)
                .padding(2)
        }
        .animation(.easeInOut(duration: 0.2), value: photo.isPick)
        .clipShape(RoundedRectangle(cornerRadius: 4))
        .overlay(
            // strokeBorder draws inside the frame; plain stroke would center
            // on the edge and clip the outer half.
            RoundedRectangle(cornerRadius: 4)
                .strokeBorder(borderColor, lineWidth: 2)
        )
        .opacity(isDimmed ? 0.4 : 1.0)
        .animation(.easeInOut(duration: 0.15), value: isDimmed)
        .accessibilityIdentifier(Self.accessibilityID(for: photo))
        .accessibilityValue(a11ySelectionValue)
    }
}

/// In-memory thumbnail cache — survives LazyHStack recycling.
private final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 500
        cache.totalCostLimit = 50 * 1024 * 1024 // 50MB
    }

    func get(_ key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ key: String, image: NSImage) {
        let cost = Int(image.size.width * image.size.height * 4) // approx bytes (RGBA)
        cache.setObject(image, forKey: key as NSString, cost: cost)
    }
}

/// Loads a thumbnail from a file path asynchronously with caching.
struct AsyncThumbnailImage: View {
    let filePath: String
    @State private var image: NSImage?

    var body: some View {
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                Rectangle()
                    .fill(.quaternary)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.tertiary)
                    }
            }
        }
        .task {
            // Check cache first
            if let cached = ThumbnailCache.shared.get(filePath) {
                image = cached
                return
            }
            if let loaded = await loadThumbnail() {
                ThumbnailCache.shared.set(filePath, image: loaded)
                image = loaded
            }
        }
    }

    private func loadThumbnail() async -> NSImage? {
        await ImageLoader.load(path: filePath, maxPixelSize: 160)
    }
}


