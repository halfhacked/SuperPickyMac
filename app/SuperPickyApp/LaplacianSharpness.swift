import Accelerate
import CoreGraphics
import Foundation

/// Computes image sharpness via Tenengrad (Sobel gradient magnitude) with log normalization.
/// Ported from superpicky's Python implementation. Returns values in [0, 1000].
enum TenengradSharpness {

    private static let minVal: Float = 100.0
    private static let maxVal: Float = 154016.0
    private static let logMinVal: Float = log(100.0)
    private static let logRange: Float = log(154016.0) - log(100.0)

    /// Full-image sharpness score.
    static func score(image: CGImage) -> Float {
        maskedScore(image: image, centerX: image.width / 2, centerY: image.height / 2,
                    radius: max(image.width, image.height))
    }

    /// Sharpness within a circular mask (for head-region measurement).
    ///
    /// `extraMask`, when supplied, must be a `width × height` row-major byte
    /// array; pixels with a zero entry are skipped. Used to intersect the
    /// head circle with the YOLO segmentation mask so background pixels
    /// outside the bird body don't contribute, mirroring superpicky's
    /// `cv2.bitwise_and(circle_mask, seg_mask)`.
    static func maskedScore(image: CGImage, centerX: Int, centerY: Int, radius: Int,
                            extraMask: [UInt8]? = nil) -> Float {
        let w = image.width
        let h = image.height
        guard w > 2 && h > 2 && radius > 1 else { return 0 }
        if let m = extraMask, m.count != w * h { return 0 }

        guard let src = grayscaleFloats(from: image) else { return 0 }

        let r2 = radius * radius
        var sum: Double = 0
        var count = 0

        let yMin = max(1, centerY - radius)
        let yMax = min(h - 2, centerY + radius)
        let xMin = max(1, centerX - radius)
        let xMax = min(w - 2, centerX + radius)

        for y in yMin...yMax {
            let dy = y - centerY
            let rowM = (y - 1) * w
            let row0 = y * w
            let rowP = (y + 1) * w
            for x in xMin...xMax {
                let dx = x - centerX
                guard dx * dx + dy * dy <= r2 else { continue }
                if let m = extraMask, m[row0 + x] == 0 { continue }

                let gx = -src[rowM + x - 1] + src[rowM + x + 1]
                       + -2 * src[row0 + x - 1] + 2 * src[row0 + x + 1]
                       + -src[rowP + x - 1] + src[rowP + x + 1]
                let gy = -src[rowM + x - 1] - 2 * src[rowM + x] - src[rowM + x + 1]
                       + src[rowP + x - 1] + 2 * src[rowP + x] + src[rowP + x + 1]
                sum += Double(gx * gx + gy * gy)
                count += 1
            }
        }

        guard count > 0 else { return 0 }
        return logNormalize(Float(sum / Double(count)))
    }

    // MARK: - Helpers

    private static func grayscaleFloats(from image: CGImage) -> [Float]? {
        let w = image.width
        let h = image.height
        var gray = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &gray, width: w, height: h,
            bitsPerComponent: 8, bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return nil }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))

        var src = [Float](repeating: 0, count: w * h)
        vDSP_vfltu8(gray, 1, &src, 1, vDSP_Length(w * h))
        return src
    }

    private static func logNormalize(_ raw: Float) -> Float {
        guard raw > minVal else { return 0 }
        guard raw < maxVal else { return 1000 }
        return (log(raw) - logMinVal) / logRange * 1000
    }
}
