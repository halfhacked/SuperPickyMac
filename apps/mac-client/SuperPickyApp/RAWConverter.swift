import Foundation
import CoreImage
import CoreGraphics
import ImageIO

struct RAWConverter: Sendable {
    /// Max pixel dimension for detect/aesthetics/keypoints/flight inference.
    private static let maxInferenceSize = 1280

    /// Max pixel dimension for sharpness measurement. The 1280 inference
    /// crop is undersampled for sharpness — at that resolution a distant
    /// bird's head circle is 80–150 px and 1-pixel focus blur is
    /// unobservable. Decoding to ~5800 picks up the embedded full-res
    /// JPEG preview that modern bodies (Sony A1/A7Rx/A9, Canon R5/R6,
    /// Nikon Z9) write into ARW/CR3/NEF — fast enough to run per photo
    /// and recovers the ~65% raw-gradient gap we see between visually
    /// distinct shots that tied at 1280.
    static let maxSharpnessSize = 5800

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

    /// Decode a higher-resolution image for the sharpness pass. Uses the
    /// embedded full-res JPEG preview (no slow CIRAW path) and caps at
    /// `maxPixelSize` so memory stays bounded. Returns nil on failure;
    /// caller is expected to fall back to the inference image.
    func decodeForSharpness(fileURL: URL,
                            maxPixelSize: Int = RAWConverter.maxSharpnessSize) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
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
