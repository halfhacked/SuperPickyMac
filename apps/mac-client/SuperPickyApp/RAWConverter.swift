import Foundation
import CoreImage
import CoreGraphics
import ImageIO

struct RAWConverter: Sendable {
    /// Max pixel dimension for inference. Detection/classification don't need full resolution.
    private static let maxInferenceSize = 1280

    func convert(fileURL: URL) throws -> CGImage {
        let ext = fileURL.pathExtension.lowercased()
        let rawExtensions: Set<String> = ["cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "dng", "iiq", "hif"]

        if rawExtensions.contains(ext) {
            // Try fast thumbnail extraction first, fall back to CIRAWFilter
            if let thumb = try? loadThumbnail(fileURL: fileURL) {
                return thumb
            }
            return try convertRAW(fileURL: fileURL)
        } else {
            return try loadThumbnail(fileURL: fileURL)
        }
    }

    /// Fast path: extract embedded thumbnail/preview from image file, downsampled to inference size.
    private func loadThumbnail(fileURL: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil) else {
            throw RAWConversionError.conversionFailed
        }
        let options: [CFString: Any] = [
            kCGImageSourceThumbnailMaxPixelSize: Self.maxInferenceSize,
            kCGImageSourceCreateThumbnailFromImageIfAbsent: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw RAWConversionError.conversionFailed
        }
        return image
    }

    /// Slow path: full RAW decode via CIRAWFilter, downsampled.
    private func convertRAW(fileURL: URL) throws -> CGImage {
        let context = CIContext(options: [.useSoftwareRenderer: false])
        guard let filter = CIRAWFilter(imageURL: fileURL) else {
            throw RAWConversionError.unsupportedFormat(fileURL.pathExtension)
        }
        guard let outputImage = filter.outputImage else {
            throw RAWConversionError.conversionFailed
        }

        // Downsample to inference size
        let scale = min(
            CGFloat(Self.maxInferenceSize) / outputImage.extent.width,
            CGFloat(Self.maxInferenceSize) / outputImage.extent.height
        )
        let scaled: CIImage
        if scale < 1.0 {
            scaled = outputImage.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
        } else {
            scaled = outputImage
        }

        guard let cgImage = context.createCGImage(scaled, from: scaled.extent) else {
            throw RAWConversionError.conversionFailed
        }
        return cgImage
    }
}

enum RAWConversionError: Error {
    case unsupportedFormat(String)
    case conversionFailed
}
