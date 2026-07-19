import Foundation
import CoreGraphics
import Accelerate

struct ExposureResult: Sendable {
    let isOverexposed: Bool
    let isUnderexposed: Bool
    let overexposedRatio: Float
    let underexposedRatio: Float

    static let empty = ExposureResult(
        isOverexposed: false, isUnderexposed: false,
        overexposedRatio: 0, underexposedRatio: 0
    )
}

struct ExposureDetector: Sendable {
    func detect(image: CGImage, threshold: Float = 0.10) -> ExposureResult {
        let width = image.width
        let height = image.height
        let totalPixels = width * height

        guard totalPixels > 0 else {
            return .empty
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: totalPixels)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return .empty
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var histogram = [vImagePixelCount](repeating: 0, count: 256)
        let histogramError = pixels.withUnsafeMutableBytes { pixelBytes in
            var buffer = vImage_Buffer(
                data: pixelBytes.baseAddress!,
                height: vImagePixelCount(height),
                width: vImagePixelCount(width),
                rowBytes: width
            )
            return histogram.withUnsafeMutableBufferPointer { bins in
                vImageHistogramCalculation_Planar8(
                    &buffer, bins.baseAddress!, vImage_Flags(kvImageNoFlags)
                )
            }
        }
        guard histogramError == kvImageNoError else {
            return .empty
        }

        let overCount = histogram[235...255].reduce(0, +)
        let underCount = histogram[0...15].reduce(0, +)

        let overRatio = Float(overCount) / Float(totalPixels)
        let underRatio = Float(underCount) / Float(totalPixels)

        return ExposureResult(
            isOverexposed: overRatio > threshold,
            isUnderexposed: underRatio > threshold,
            overexposedRatio: overRatio,
            underexposedRatio: underRatio
        )
    }
}
