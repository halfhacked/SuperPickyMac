import Foundation
import CoreGraphics

struct ExposureResult: Sendable {
    let isOverexposed: Bool
    let isUnderexposed: Bool
    let overexposedRatio: Float
    let underexposedRatio: Float
}

struct ExposureDetector: Sendable {
    /// Internal pixel-clipping thresholds. Independent of the user-adjustable
    /// `CullingConfig.exposureThreshold`, which is passed through as `threshold`.
    enum Thresholds {
        /// Pixels >= 235/255 are treated as near-white clipping; the small margin
        /// below pure white avoids flagging deliberately bright highlights.
        static let overexposedPixelValue: UInt8 = 235

        /// Pixels <= 15/255 are treated as near-black clipping; the small margin
        /// above pure black avoids flagging recoverable shadow detail.
        static let underexposedPixelValue: UInt8 = 15

        /// Default fraction of clipped pixels (10%) that trips the over/under flag
        /// when the caller doesn't supply its own threshold.
        static let defaultClippingRatio: Float = 0.10
    }

    func detect(image: CGImage, threshold: Float = Thresholds.defaultClippingRatio) -> ExposureResult {
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
            if pixel >= Thresholds.overexposedPixelValue { overCount += 1 }
            if pixel <= Thresholds.underexposedPixelValue { underCount += 1 }
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
