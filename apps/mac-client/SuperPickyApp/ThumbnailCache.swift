import SwiftUI
import AppKit

/// In-memory thumbnail cache — survives LazyHStack recycling.
final class ThumbnailCache {
    static let shared = ThumbnailCache()
    private let cache = NSCache<NSString, NSImage>()

    init() {
        cache.countLimit = 500
    }

    func get(_ key: String) -> NSImage? {
        cache.object(forKey: key as NSString)
    }

    func set(_ key: String, image: NSImage) {
        cache.setObject(image, forKey: key as NSString)
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
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                let options: [CFString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: 160,
                    kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                guard let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
                    continuation.resume(returning: nil)
                    return
                }
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                continuation.resume(returning: nsImage)
            }
        }
    }
}
