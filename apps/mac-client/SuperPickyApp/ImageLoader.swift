import Foundation
import CoreGraphics
import ImageIO
import AppKit

/// Shared image loading utility — used by PreviewView, FullscreenViewer, and ThumbnailStripView.
enum ImageLoader {
    /// Load an image at a given max pixel size, or full resolution if nil.
    /// Uses embedded preview for speed (IfAbsent), or full decode for full-res.
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
                    cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                        kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                        kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
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

    /// Read actual pixel width from file metadata (no decode — fast).
    static func pixelWidth(path: String) -> CGFloat? {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let w = props[kCGImagePropertyPixelWidth as String] as? CGFloat else {
            return nil
        }
        return w
    }
}
