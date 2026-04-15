import Accelerate
import CoreGraphics

/// Computes image sharpness via Laplacian variance on a CGImage.
/// Higher scores indicate sharper images. Returns values in approximately [0, 600].
enum LaplacianSharpness {

    /// Compute sharpness of `image` using the Laplacian variance method.
    ///
    /// The discrete Laplacian L[y,x] = src[y-1,x] + src[y+1,x] + src[y,x-1] + src[y,x+1] - 4*src[y,x]
    /// captures edge density — sharp images have high-frequency edges and thus higher variance.
    ///
    /// Calibration: variance ~333 → score 100 (minimum threshold), ~1267 → score 380 (default threshold).
    static func score(image: CGImage) -> Float {
        let w = image.width
        let h = image.height
        guard w > 2 && h > 2 else { return 0 }

        // Render to 8-bit planar grayscale
        var gray = [UInt8](repeating: 0, count: w * h)
        guard let ctx = CGContext(
            data: &gray,
            width: w,
            height: h,
            bitsPerComponent: 8,
            bytesPerRow: w,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else { return 0 }
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: CGFloat(w), height: CGFloat(h)))

        // Upconvert uint8 → Float using vDSP
        let n = w * h
        var src = [Float](repeating: 0, count: n)
        vDSP_vfltu8(gray, 1, &src, 1, vDSP_Length(n))

        // Compute Laplacian only for interior pixels; border stays 0
        var lap = [Float](repeating: 0, count: n)
        for y in 1..<(h - 1) {
            let row = y * w
            for x in 1..<(w - 1) {
                let i = row + x
                lap[i] = src[i - w] + src[i + w] + src[i - 1] + src[i + 1] - 4 * src[i]
            }
        }

        // Variance = E[L²] - E[L]²  (using vDSP for the statistics)
        let len = vDSP_Length(n)
        var mean: Float = 0
        var meanSq: Float = 0
        var sq = [Float](repeating: 0, count: n)
        vDSP_vsq(lap, 1, &sq, 1, len)
        vDSP_meanv(lap, 1, &mean, len)
        vDSP_meanv(sq, 1, &meanSq, len)
        let variance = max(0, meanSq - mean * mean)

        // Scale: variance 333 → score 100 (minimum threshold), 1267 → score 380 (default threshold)
        return min(variance * 0.3, 600)
    }
}
