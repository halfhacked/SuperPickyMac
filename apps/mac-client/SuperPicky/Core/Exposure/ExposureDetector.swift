import Foundation
import CoreGraphics

struct ExposureResult: Sendable {
    let isOverexposed: Bool
    let isUnderexposed: Bool
    let overexposedRatio: Float
    let underexposedRatio: Float
}

struct ExposureDetector: Sendable {
    func detect(image: CGImage, threshold: Float = 0.10) -> ExposureResult {
        let width = image.width
        let height = image.height
        let totalPixels = width * height

        guard totalPixels > 0 else {
            return ExposureResult(isOverexposed: false, isUnderexposed: false, overexposedRatio: 0, underexposedRatio: 0)
        }

        let colorSpace = CGColorSpaceCreateDeviceGray()
        var pixels = [UInt8](repeating: 0, count: totalPixels)
        guard let context = CGContext(
            data: &pixels, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: width,
            space: colorSpace, bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {
            return ExposureResult(isOverexposed: false, isUnderexposed: false, overexposedRatio: 0, underexposedRatio: 0)
        }
        context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

        var overCount = 0
        var underCount = 0
        for pixel in pixels {
            if pixel >= 235 { overCount += 1 }
            if pixel <= 15 { underCount += 1 }
        }

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
