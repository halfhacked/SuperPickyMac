import Foundation
import CoreImage
import CoreGraphics
import ImageIO

struct RAWConverter: Sendable {
    func convert(fileURL: URL) throws -> CGImage {
        let ext = fileURL.pathExtension.lowercased()
        let rawExtensions: Set<String> = ["cr2", "cr3", "nef", "arw", "raf", "orf", "rw2", "pef", "dng", "iiq", "hif"]

        if rawExtensions.contains(ext) {
            return try convertRAW(fileURL: fileURL)
        } else {
            return try loadImage(fileURL: fileURL)
        }
    }

    private func convertRAW(fileURL: URL) throws -> CGImage {
        let context = CIContext()
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

    private func loadImage(fileURL: URL) throws -> CGImage {
        guard let source = CGImageSourceCreateWithURL(fileURL as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
            throw RAWConversionError.conversionFailed
        }
        return image
    }
}

enum RAWConversionError: Error {
    case unsupportedFormat(String)
    case conversionFailed
}
