import SwiftUI

struct ThumbnailStripView: View {
    let photos: [Photo]
    @Binding var selectedPhotoID: UUID?

    var body: some View {
        let selectedBurstGroupID: UUID? = {
            guard let id = selectedPhotoID else { return nil }
            return photos.first(where: { $0.id == id })?.burstGroupID
        }()
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: true) {
                LazyHStack(spacing: 4) {
                    ForEach(photos) { photo in
                        ThumbnailCell(
                            photo: photo,
                            isSelected: photo.id == selectedPhotoID,
                            isDimmed: ThumbnailCell.shouldDim(
                                photoBurstGroupID: photo.burstGroupID,
                                selectedBurstGroupID: selectedBurstGroupID
                            )
                        )
                            .id(photo.id)
                            .onTapGesture {
                                selectedPhotoID = photo.id
                            }
                    }
                }
                .padding(.horizontal, 4)
                .padding(.vertical, 6)
            }
            .background(ScrollWheelRedirector())
            .background(.bar)
            .onChange(of: selectedPhotoID) { _, newValue in
                if let id = newValue {
                    withAnimation {
                        proxy.scrollTo(id, anchor: .center)
                    }
                }
            }
        }
    }
}

struct ThumbnailCell: View {
    let photo: Photo
    let isSelected: Bool
    let isDimmed: Bool

    /// A thumbnail is dimmed only when the selected photo is part of a burst
    /// and this thumbnail belongs to a different burst (or to no burst at all).
    /// Singletons (selected photo has no burst) leave every thumbnail at full opacity.
    static func shouldDim(photoBurstGroupID: UUID?, selectedBurstGroupID: UUID?) -> Bool {
        guard let selected = selectedBurstGroupID else { return false }
        return photoBurstGroupID != selected
    }

    private var borderColor: Color {
        if isSelected { return .accentColor }
        if photo.isPick { return .orange.opacity(0.6) }
        return .clear
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
        .accessibilityIdentifier("Thumbnail_\(photo.filename)")
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


