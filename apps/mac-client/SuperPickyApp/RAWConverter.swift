import Foundation
import CoreImage
import CoreGraphics
import ImageIO

struct RAWConverter: Sendable {
    func convert(fileURL: URL) throws -> CGImage {
        let ext = fileURL.pathExtension.lowercased()
        let rawExtensions: Set<String> = ["cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "dng", "iiq", "hif"]

        if rawExtensions.contains(ext) {
            // Extract embedded JPEG from RAW (fast — no RAW decoding)
            if let embedded = loadEmbeddedJPEG(fileURL: fileURL) {
                return embedded
            }
            // Fallback: full RAW decode
            return try convertRAW(fileURL: fileURL)
        } else {
            return try loadImage(fileURL: fileURL)
        }
    }

    /// Extract the pre-rendered JPEG embedded in RAW files — no RAW decoding needed.
    /// Returns full-resolution embedded JPEG (~8640x5760 for Sony ARW).
    private func loadEmbeddedJPEG(fileURL: URL) -> CGImage? {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            return nil
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
    }

    /// Load a standard image file (JPEG, PNG, HEIC, etc.)
    private func loadImage(fileURL: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RAWConversionError.conversionFailed
        }
        return image
    }

    /// Slow path: full RAW decode via CIRAWFilter.
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
