import Foundation
import CoreGraphics
import ImageIO
import AppKit
import os

/// Shared image loading utility — used by PreviewView, FullscreenViewer, and ThumbnailStripView.
enum ImageLoader {
    private static let log = Logger(subsystem: "com.halfhacked.superpicky", category: "ImageLoader")

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

    /// Sendable-friendly decode for the foreground hot path. Serialized
    /// through `ImageDecodeQueue` so holding arrow doesn't pile up N
    /// concurrent RAW decodes; eager-decoded so the main thread doesn't
    /// stall when SwiftUI renders the NSImage.
    ///
    /// Small previews (≤ 320 px on the long side) bypass the serial queue:
    /// they're cheap (~5–10 ms via embedded thumbnail) and routing them
    /// behind a slow full-res RAW decode is what made the thumbnail strip
    /// flash gray placeholders during fast arrow navigation.
    static func loadCGImage(path: String, maxPixelSize: Int? = nil) async -> CGImage? {
        if let cap = maxPixelSize, cap <= 320 {
            return await loadCGImageThumbnail(path: path, maxPixelSize: cap)
        }
        return await ImageDecodeQueue.shared.decode {
            decodeCore(path: path, maxPixelSize: maxPixelSize, tag: "FG", eager: true)
        }
    }

    /// Concurrent decode path for thumbnail-strip / sidebar loads. No
    /// serial gate — multiple thumbnails can decode in parallel and none
    /// of them ever block behind the foreground full-res decode.
    private static func loadCGImageThumbnail(path: String, maxPixelSize: Int) async -> CGImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                continuation.resume(returning: decodeCore(path: path, maxPixelSize: maxPixelSize, tag: "THUMB", eager: false))
            }
        }
    }

    /// Background decode that pre-warms the in-memory cache (prefetch).
    /// Eager-decoded — same reason as foreground. Serialized through a
    /// dedicated queue so 6 same-burst prefetches don't allocate 6 × 96 MB
    /// concurrently.
    static func loadCGImagePrefetch(path: String, maxPixelSize: Int? = nil, tag: String = "PREFETCH") async -> CGImage? {
        await withCheckedContinuation { continuation in
            prefetchDecodeQueue.async {
                continuation.resume(returning: decodeCore(path: path, maxPixelSize: maxPixelSize, tag: tag, eager: true))
            }
        }
    }

    private static let prefetchDecodeQueue: DispatchQueue = {
        DispatchQueue(label: "com.halfhacked.superpicky.prefetchDecode", qos: .utility)
    }()

    /// Background decode for the disk-cache sweep — discards the result
    /// after the JPEG is written, so we deliberately skip the eager decode
    /// (no display pending) and avoid allocating a full-resolution bitmap
    /// per swept photo.
    static func loadCGImageSweep(path: String, maxPixelSize: Int? = nil) async -> CGImage? {
        await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .utility).async {
                continuation.resume(returning: decodeCore(path: path, maxPixelSize: maxPixelSize, tag: "SWEEP", eager: false))
            }
        }
    }

    /// Shared decode body. Returns the cached full-res JPEG when present,
    /// otherwise decodes from source and (for full-res, when enabled)
    /// enqueues a serialised JPEG write. Set `eager` only for paths that
    /// will hand the bitmap to AppKit/SwiftUI for display — eager decoding
    /// allocates a full-resolution backing buffer (~96 MB for ARW).
    private static func decodeCore(path: String, maxPixelSize: Int?, tag: String, eager: Bool) -> CGImage? {
        let basename = (path as NSString).lastPathComponent
        let started = DispatchTime.now()

        if maxPixelSize == nil, let cached = loadCachedFullRes(path: path, eager: eager) {
            let ms = elapsedMs(since: started)
            log.info("[\(tag, privacy: .public)] HIT \(basename, privacy: .public) \(ms, privacy: .public)ms")
            return cached
        }
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            log.error("[\(tag, privacy: .public)] OPEN-FAIL \(basename, privacy: .public)")
            return nil
        }
        if let maxPixelSize {
            let result = decodePreview(source: source, maxPixelSize: maxPixelSize)
            let ms = elapsedMs(since: started)
            log.info("[\(tag, privacy: .public)] PREVIEW \(maxPixelSize)px \(basename, privacy: .public) \(ms, privacy: .public)ms")
            return result
        }
        // ShouldCache pins the decoded bitmap inside the source. We only
        // want that for paths that will return the bitmap to a caller —
        // for the sweep we throw it away after the JPEG encode.
        let createOpts: [CFString: Any] = eager
            ? [kCGImageSourceShouldCache: true,
               kCGImageSourceShouldCacheImmediately: true,
               kCGImageSourceCreateThumbnailWithTransform: true]
            : [kCGImageSourceShouldCache: false,
               kCGImageSourceCreateThumbnailWithTransform: true]
        let cgImage = CGImageSourceCreateImageAtIndex(source, 0, createOpts as CFDictionary)

        let result: CGImage?
        if let cgImage, eager {
            result = forceDecode(cgImage)
        } else {
            result = cgImage
        }

        let s = PreviewCache.settings
        if let imageForEncode = result, s.generate, !Task.isCancelled {
            if eager {
                // Eager bitmap holds its own pixels; the writer queue can
                // encode without re-reading the source. Take the encode
                // off the caller's await path — they get the image ~50–100
                // ms sooner.
                schedulePreviewCacheEncodeAndWrite(image: imageForEncode, rawPath: path, capBytes: s.capBytes)
            } else {
                // Sweep path: lazy CGImage references the source. Encode
                // synchronously while pixels are still in ImageIO's read
                // buffer; otherwise the writer queue would re-decode from
                // disk. The caller throws away `result` immediately, so
                // there's no perceived latency to protect.
                if let data = PreviewCache.encodeJPEG(imageForEncode) {
                    schedulePreviewCacheWriteBytes(data: data, rawPath: path, capBytes: s.capBytes)
                }
            }
        }

        let ms = elapsedMs(since: started)
        log.info("[\(tag, privacy: .public)] MISS \(basename, privacy: .public) \(ms, privacy: .public)ms eager=\(eager, privacy: .public) write=\(s.generate, privacy: .public)")
        return result
    }

    /// Render the image into a same-sized bitmap context and return the
    /// resulting CGImage. This forces ImageIO's lazy decode to complete on
    /// this background thread; without it, the pixel decode is deferred
    /// until SwiftUI draws the NSImage on the main thread, blocking the UI
    /// for hundreds of ms per photo on RAW files.
    private static func forceDecode(_ image: CGImage) -> CGImage {
        let w = image.width
        let h = image.height
        let cs = CGColorSpaceCreateDeviceRGB()
        guard let ctx = CGContext(
            data: nil, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w * 4,
            space: cs,
            bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue
                | CGBitmapInfo.byteOrder32Little.rawValue
        ) else { return image }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return ctx.makeImage() ?? image
    }

    private static func elapsedMs(since start: DispatchTime) -> Int {
        let ns = DispatchTime.now().uptimeNanoseconds &- start.uptimeNanoseconds
        return Int(ns / 1_000_000)
    }

    /// Returns a decoded CGImage from the on-disk JPEG cache when available
    /// and fresher than the source. Bumps the cached file's mtime on hit so
    /// LRU eviction sees recent reads as recently used. `eager=false`
    /// returns a lazy CGImage; the sweep uses this and immediately discards.
    private static func loadCachedFullRes(path: String, eager: Bool) -> CGImage? {
        guard let cachedURL = PreviewCache.freshURL(for: path) else { return nil }
        let opts: [CFString: Any] = eager
            ? [kCGImageSourceShouldCache: true, kCGImageSourceShouldCacheImmediately: true]
            : [:]
        guard let source = CGImageSourceCreateWithURL(cachedURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, opts as CFDictionary) else {
            return nil
        }
        PreviewCache.touch(cachedURL)
        return eager ? forceDecode(image) : image
    }

    /// Serial queue for JPEG cache writes. Each write decodes the source's
    /// pixels into RAM to encode JPEG; running many writes concurrently
    /// multiplies that working set. One at a time keeps memory bounded
    /// while still completing in the background.
    private static let cacheWriteQueue: DispatchQueue = {
        let q = DispatchQueue(label: "com.halfhacked.superpicky.previewCacheWrite", qos: .background)
        return q
    }()

    /// Enqueue a serialised disk write of pre-encoded JPEG bytes. The
    /// writer holds only the Data buffer (~5 MB) and the path string —
    /// it does not retain the source CGImage / CGImageSource, so a
    /// backlog of pending writes can't pin decoded bitmaps in memory.
    private static func schedulePreviewCacheWriteBytes(data: Data, rawPath: String, capBytes: Int64) {
        let url = PreviewCache.cachedURL(for: rawPath)
        cacheWriteQueue.async {
            PreviewCache.writeData(data, to: url)
            if capBytes > 0 { PreviewCache.evictIfOverCap(maxBytes: capBytes) }
        }
    }

    /// Enqueue a serialised JPEG encode + disk write. Used for the eager
    /// foreground / prefetch paths where the bitmap is held by the CGImage
    /// itself, so the encode is just walking pixels (no source re-read)
    /// and is safe to do asynchronously off the caller's await path.
    private static func schedulePreviewCacheEncodeAndWrite(image: CGImage, rawPath: String, capBytes: Int64) {
        let url = PreviewCache.cachedURL(for: rawPath)
        cacheWriteQueue.async {
            guard let data = PreviewCache.encodeJPEG(image) else { return }
            PreviewCache.writeData(data, to: url)
            if capBytes > 0 { PreviewCache.evictIfOverCap(maxBytes: capBytes) }
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
