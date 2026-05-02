import Foundation
import CoreGraphics
import ImageIO
import AppKit

/// Shared image loading utility — used by PreviewView, FullscreenViewer, and ThumbnailStripView.
enum ImageLoader {
    /// Disk-cache full-res decodes as JPEG sidecars under
    /// `~/Library/Caches/com.halfhacked.superpicky/preview/`. Set to false
    /// to read existing cache entries but skip writing new ones.
    nonisolated(unsafe) static var generatePreviewCache: Bool = true

    /// LRU cap in bytes; 0 means unlimited. Mirrored from
    /// `CullingConfig.previewCacheSizeGB` at app boot and on changes.
    nonisolated(unsafe) static var previewCacheCapBytes: Int64 = 20 * 1024 * 1024 * 1024

    /// Load an image at a given max pixel size, or full resolution if nil.
    /// Uses the embedded preview when it's large enough (fast path for RAW),
    /// otherwise decodes the full image and downsamples.
    ///
    /// NSImage isn't Sendable, so decode returns a CGImage from the
    /// background queue (Sendable) and the MainActor-isolated caller wraps
    /// it — which also keeps AppKit construction off the worker thread.
    @MainActor
    static func load(path: String, maxPixelSize: Int? = nil) async -> NSImage? {
        guard let cgImage = await loadCGImage(path: path, maxPixelSize: maxPixelSize) else {
            return nil
        }
        return NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
    }

    /// Sendable-friendly decode. Useful for `async let` / `TaskGroup`
    /// concurrency where NSImage's non-Sendable result would error.
    /// Call sites wrap in NSImage on their own actor.
    ///
    /// All decodes are serialized through `ImageDecodeQueue.shared` so that
    /// holding an arrow key in zoom mode doesn't pile up N concurrent RAW
    /// decodes — only one runs at a time, and cancelled callers drop their
    /// turn at the front of the queue without doing any work.
    static func loadCGImage(path: String, maxPixelSize: Int? = nil) async -> CGImage? {
        return await ImageDecodeQueue.shared.decode {
            if maxPixelSize == nil, let cached = loadCachedFullRes(path: path) {
                return cached
            }
            let url = URL(fileURLWithPath: path)
            guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                return nil
            }
            if let maxPixelSize {
                return decodePreview(source: source, maxPixelSize: maxPixelSize)
            }
            let cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
            if let cgImage, generatePreviewCache {
                writePreviewCacheAsync(image: cgImage, rawPath: path)
            }
            return cgImage
        }
    }

    /// Returns a decoded CGImage from the on-disk JPEG cache when available
    /// and fresher than the source. Bumps the cached file's mtime on hit so
    /// LRU eviction sees recent reads as recently used.
    private static func loadCachedFullRes(path: String) -> CGImage? {
        guard let cachedURL = PreviewCache.freshURL(for: path) else { return nil }
        guard let source = CGImageSourceCreateWithURL(cachedURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            return nil
        }
        PreviewCache.touch(cachedURL)
        return image
    }

    /// Encode + write the cache off the decode thread; LRU eviction follows.
    private static func writePreviewCacheAsync(image: CGImage, rawPath: String) {
        let url = PreviewCache.cachedURL(for: rawPath)
        let cap = previewCacheCapBytes
        Task.detached(priority: .background) {
            PreviewCache.write(image, to: url)
            if cap > 0 { PreviewCache.evictIfOverCap(maxBytes: cap) }
        }
    }

    /// Return a preview CGImage sized at most `maxPixelSize` on its longest side.
    ///
    /// The decode strategy is driven by the *embedded thumbnail's* actual size,
    /// not by the source's dimensions. Many containers advertise a large source
    /// but embed only a tiny EXIF thumbnail — e.g. a 6000 px JPG with a 160 px
    /// thumb. Using that thumb for a 2000 px preview would upscale 12× and look
    /// visibly blurry (the reported bug in #47); those cases must decode from
    /// the full image. Conversely, RAW files embed a ~1616 px preview that
    /// satisfies a 2000 px request with only a ~1.24× upscale, and decoding
    /// the full RAW would be needlessly expensive — so we reuse it directly.
    private static func decodePreview(source: CGImageSource, maxPixelSize: Int) -> CGImage? {
        let embeddedThumb = embeddedThumbnail(source: source)
        let embeddedSide = embeddedThumb.map { max($0.width, $0.height) } ?? 0
        // Accept the embedded thumbnail when it's at least two-thirds of the
        // target size — a 1.5× on-screen upscale is the largest that still
        // looks sharp to the eye. Below that threshold, decode the full image.
        let embeddedIsSharpEnough = embeddedSide * 3 >= maxPixelSize * 2
        if embeddedIsSharpEnough, let embeddedThumb {
            if embeddedSide <= maxPixelSize {
                // Reuse probe — already within the target size cap.
                return embeddedThumb
            }
            // Embedded thumb is larger than target: re-decode with size cap.
            return CGImageSourceCreateThumbnailAtIndex(source, 0, [
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ] as CFDictionary)
        }
        // No embedded thumb, or too small to produce a sharp preview —
        // force a decode of the full image downsampled to maxPixelSize.
        return CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }

    /// Decode only the container's embedded thumbnail. Returns nil if none
    /// exists (ImageIO does not synthesise one from the full image because
    /// both `IfAbsent` and `Always` are explicitly false). `MaxPixelSize`
    /// must be set — without it the function returns the full image.
    private static func embeddedThumbnail(source: CGImageSource) -> CGImage? {
        CGImageSourceCreateThumbnailAtIndex(source, 0, [
            kCGImageSourceThumbnailMaxPixelSize: embeddedThumbnailProbeCap,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: false,
            kCGImageSourceCreateThumbnailFromImageAlways: false,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ] as CFDictionary)
    }

    /// Larger than any plausible embedded-thumbnail side so the probe
    /// returns the thumb at its native dimensions.
    private static let embeddedThumbnailProbeCap = 99_999

    /// Serializes ImageIO decodes so superseded work (e.g. arrow-key
    /// scrubbing in zoom mode) drops at the front of the queue instead of
    /// piling up on a concurrent dispatch queue and saturating CPU.
    ///
    /// Each `decode` call awaits its turn on the actor; when its turn comes
    /// the closure runs synchronously on the actor's executor (one decode
    /// in flight at a time), and cancelled callers short-circuit before
    /// touching ImageIO. ImageIO has no abort API, so a started decode
    /// always runs to completion — we only prevent the queue itself from
    /// fan-out.
    actor ImageDecodeQueue {
        static let shared = ImageDecodeQueue()

        func decode(_ work: @Sendable () -> CGImage?) -> CGImage? {
            if Task.isCancelled { return nil }
            return work()
        }
    }

    /// Source dimensions in pixels (no decode — metadata only).
    static func pixelSize(path: String) -> CGSize? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
        return sourcePixelSize(source: source)
    }

    private static func sourcePixelSize(source: CGImageSource) -> CGSize? {
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let w = props[kCGImagePropertyPixelWidth as String] as? Int,
              let h = props[kCGImagePropertyPixelHeight as String] as? Int else {
            return nil
        }
        // `load` decodes with `CreateThumbnailWithTransform: true`, so the
        // displayed NSImage has EXIF orientation already applied. Swap
        // width/height for 90°/270° rotations so callers reasoning about
        // on-screen dimensions (e.g. the `z` key 1:1 zoom) stay consistent.
        let orientation = props[kCGImagePropertyOrientation as String] as? Int ?? 1
        let rotated = (5...8).contains(orientation)
        return rotated
            ? CGSize(width: h, height: w)
            : CGSize(width: w, height: h)
    }
}
