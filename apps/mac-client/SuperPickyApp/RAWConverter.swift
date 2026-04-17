import Foundation
import CoreImage
import CoreGraphics
import ImageIO

struct RAWConverter: Sendable {
    /// Max pixel dimension for detect/aesthetics/keypoints/flight inference.
    private static let maxInferenceSize = 1280

    /// Decoded thumbnail plus the EXIF/TIFF property dictionary read from
    /// the same CGImageSource. `processOnePhoto` needs both for every
    /// photo, and opening the source twice (one thumbnail, one properties)
    /// adds ~4 ms of mmap / header parsing per photo. This struct lets the
    /// pipeline reuse a single source open for both.
    struct Decoded {
        let image: CGImage
        let properties: [String: Any]?
    }

    func convert(fileURL: URL) throws -> CGImage {
        try decode(fileURL: fileURL).image
    }

    func decode(fileURL: URL) throws -> Decoded {
        let ext = fileURL.pathExtension.lowercased()
        let rawExtensions: Set<String> = ["cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "dng", "iiq", "hif"]

        if rawExtensions.contains(ext) {
            if let decoded = loadThumbnailWithProps(fileURL: fileURL) {
                return decoded
            }
            // Fallback: full RAW decode, no EXIF (CIRAWFilter path).
            return Decoded(image: try convertRAW(fileURL: fileURL), properties: nil)
        } else {
            return try loadImageWithProps(fileURL: fileURL)
        }
    }

    /// Fast: open source once, read properties, extract embedded preview.
    private func loadThumbnailWithProps(fileURL: URL) -> Decoded? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else { return nil }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: Self.maxInferenceSize,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let thumb = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            return nil
        }
        return Decoded(image: thumb, properties: props)
    }

    /// Load standard image files.
    private func loadImageWithProps(fileURL: URL) throws -> Decoded {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            throw RAWConversionError.conversionFailed
        }
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any]
        guard let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RAWConversionError.conversionFailed
        }
        return Decoded(image: image, properties: props)
    }

    /// Slow fallback: full RAW decode.
    private func convertRAW(fileURL: URL) throws -> CGImage {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let filter = CIRAWFilter(imageURL: fileURL) else {
            throw RAWConversionError.unsupportedFormat(fileURL.pathExtension)
        }
        guard let outputImage = filter.outputImage else {
            throw RAWConversionError.conversionFailed
        }
        guard let cgImage = context.createCGImage(outputImage, from: outputImage.extent) else {
            throw RAWConversionError.conversionFailed
        }
        return cgImage
    }
}

enum RAWConversionError: Error {
    case unsupportedFormat(String)
    case conversionFailed
}
