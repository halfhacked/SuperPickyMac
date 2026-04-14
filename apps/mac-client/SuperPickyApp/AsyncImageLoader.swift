import Foundation
import AppKit
import ImageIO

/// Shared async image-loading utility used by `PreviewView` and `FullscreenViewer`.
///
/// Both call sites previously duplicated the same `CGImageSource` thumbnail
/// pipeline. This namespace preserves that exact pipeline and exposes it as a
/// single entry point parameterized by the target pixel size.
enum AsyncImageLoader {
    /// Target size presets for the two existing call sites.
    ///
    /// - `preview`  : ~2000 px max, prefers the embedded preview when present
    ///                (fast for RAW — avoids a full decode).
    /// - `fullscreen`: ~4000 px max, always decodes from the image itself.
    enum Size {
        case preview
        case fullscreen

        fileprivate var maxPixelSize: Int {
            switch self {
            case .preview: return 2000
            case .fullscreen: return 4000
            }
        }

        /// Whether to force a thumbnail decode from the full image even if an
        /// embedded preview is available. `fullscreen` always decodes so the
        /// zoomed view gets full resolution; `preview` is allowed to use the
        /// embedded thumbnail for speed.
        fileprivate var alwaysFromImage: Bool {
            switch self {
            case .preview: return false
            case .fullscreen: return true
            }
        }
    }

    /// Decodes the image at `filePath` to an `NSImage` sized for `size`.
    ///
    /// Returns `nil` if the file is missing or the image source cannot be
    /// decoded. Runs the `CGImageSource` work on a background queue.
    static func load(filePath: String, size: Size) async -> NSImage? {
        let url = URL(fileURLWithPath: filePath)
        guard FileManager.default.fileExists(atPath: filePath) else { return nil }

        return await withCheckedContinuation { continuation in
            DispatchQueue.global(qos: .userInitiated).async {
                guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
                    continuation.resume(returning: nil)
                    return
                }
                var options: [CFString: Any] = [
                    kCGImageSourceThumbnailMaxPixelSize: size.maxPixelSize,
                    kCGImageSourceCreateThumbnailWithTransform: true,
                ]
                if size.alwaysFromImage {
                    options[kCGImageSourceCreateThumbnailFromImageAlways] = true
                } else {
                    options[kCGImageSourceCreateThumbnailFromImageIfAbsent] = true
                }
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
