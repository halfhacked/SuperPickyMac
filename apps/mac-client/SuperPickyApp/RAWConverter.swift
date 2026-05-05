import Foundation
import CoreImage
import CoreGraphics
import ImageIO

struct RAWConverter: Sendable {
    /// Max pixel dimension for detect/aesthetics/keypoints/flight inference.
    private static let maxInferenceSize = 1280

    /// Max pixel dimension for sharpness measurement. The 1280 inference
    /// crop is undersampled — at that resolution a distant bird's head
    /// circle is 80–150 px and 1-pixel focus blur is unobservable; two
    /// visibly distinct shots tie within 0.1 %.
    ///
    /// Sized for libjpeg-turbo's scaled IDCT: for a Sony A1 5616-px
    /// source, ≤3510 keeps the decoder on the 3/4-scale path; the next
    /// step (7/8) costs substantially more wall time for negligible
    /// discrimination gain.
    static let maxSharpnessSize = 3500

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

    /// Decode a higher-resolution image for the sharpness pass.
    ///
    /// Sony ARW: extract the embedded full-res JPEG (5616×3744 on A1,
    /// 8640×5760 on A1 II / A7R V) directly from IFD2 and decode it.
    /// Bypasses ImageIO's CIRAW path which costs ~611 ms per A1 ARW —
    /// the embedded-JPEG path costs ~70 ms.
    ///
    /// Other RAW formats (CR3, NEF, RAF, …) and JPEG/HEIC fall back to
    /// `kCGImageSourceCreateThumbnailFromImageAlways`. That's still slow
    /// for non-Sony RAW (also CIRAW for those) but correct;
    /// `kCGImageSourceCreateThumbnailFromImageIfAbsent` would silently
    /// return the small embedded preview and we'd be back to the
    /// 1280-equivalent resolution problem.
    ///
    /// Returns nil only when both the ARW fast path and the ImageIO
    /// fallback fail. Caller falls back to the inference image.
    func decodeForSharpness(fileURL: URL,
                            maxPixelSize: Int = RAWConverter.maxSharpnessSize) -> CGImage? {
        let ext = fileURL.pathExtension.lowercased()
        if ext == "arw",
           let jpegData = ARWPreviewExtractor.extractFullResJPEG(from: fileURL.path),
           let source = CGImageSourceCreateWithData(jpegData as CFData, nil) {
            let options: [CFString: Any] = [
                kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
                kCGImageSourceCreateThumbnailFromImageAlways: true,
                kCGImageSourceCreateThumbnailWithTransform: true,
            ]
            if let img = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) {
                return img
            }
        }

        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
            kCGImageSourceCreateThumbnailFromImageAlways: true,
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
