import Foundation
import CoreGraphics
import ImageIO
import AppKit

/// Shared image loading utility — used by PreviewView, FullscreenViewer, and ThumbnailStripView.
enum ImageLoader {
    /// Load an image at a given max pixel size, or full resolution if nil.
    /// Uses the embedded preview when it's large enough (fast path for RAW),
    /// otherwise decodes the full image and downsamples.
    static func load(path: String, maxPixelSize: Int? = nil) async -> NSImage? {
        let url = URL(fileURLWithPath: path)

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    continuation.resume(returning: nil)
                    return
                }

                let cgImage: CGImage?
                if let maxPixelSize {
                    // RAWs embed a ~1600 px preview that satisfies `maxPixelSize`;
                    // use it (IfAbsent). Smaller sources (e.g. 1600 px JPEGs
                    // with only a 160 px embedded thumbnail) must fall through
                    // to a real decode — `IfAbsent` would prefer the tiny
                    // thumbnail and the preview ends up blurry.
                    let sourceSide = sourceMaxDimension(source: source)
                    let useEmbedded = sourceSide > maxPixelSize
                    cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                        (useEmbedded
                         ? kCGImageSourceCreateThumbnailFromImageIfAbsent
                         : kCGImageSourceCreateThumbnailFromImageAlways): true,
                        kCGImageSourceCreateThumbnailWithTransform: true,
                    ] as CFDictionary)
                } else {
                    // Full-res: actual image decode
                    cgImage = CGImageSourceCreateImageAtIndex(source, 0, [
                        kCGImageSourceCreateThumbnailWithTransform: true,
                    ] as CFDictionary)
                }

                guard let cgImage else {
                    continuation.resume(returning: nil)
                    return
                }
                let nsImage = NSImage(cgImage: cgImage, size: NSSize(width: cgImage.width, height: cgImage.height))
                continuation.resume(returning: nsImage)
            }
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

    private static func sourceMaxDimension(source: CGImageSource) -> Int {
        guard let size = sourcePixelSize(source: source) else { return 0 }
        return max(Int(size.width), Int(size.height))
    }
}
