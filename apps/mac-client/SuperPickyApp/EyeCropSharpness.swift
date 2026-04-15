import Foundation
import CoreGraphics

struct EyeCropSharpness {
    static let minimumVisibility: Float = 0.3
    static let patchFraction: Float = 0.1
    static let minimumPatchSize: Int = 8

    /// Returns Laplacian sharpness of a small patch centered on the best visible eye.
    /// Returns nil if both eyes have visibility < minimumVisibility or coordinates are nil.
    static func score(
        birdCrop: CGImage,
        leftEyeX: Float?, leftEyeY: Float?, leftEyeVis: Float?,
        rightEyeX: Float?, rightEyeY: Float?, rightEyeVis: Float?
    ) -> Float? {
        let leftVis = leftEyeVis ?? 0
        let rightVis = rightEyeVis ?? 0

        // Pick the eye with higher visibility that meets the minimum threshold.
        // Fall through to the other eye if coords are nil.
        let eyeX: Float
        let eyeY: Float
        if leftVis >= minimumVisibility && leftVis >= rightVis,
           let x = leftEyeX, let y = leftEyeY {
            eyeX = x; eyeY = y
        } else if rightVis >= minimumVisibility,
                  let x = rightEyeX, let y = rightEyeY {
            eyeX = x; eyeY = y
        } else {
            return nil
        }

        let w = birdCrop.width
        let h = birdCrop.height

        let patchSize = max(minimumPatchSize, Int(Float(min(w, h)) * patchFraction))

        // Image must be large enough to accommodate the minimum patch
        guard w >= patchSize && h >= patchSize else { return nil }

        let half = patchSize / 2

        let cx = Int(eyeX * Float(w))
        let cy = Int(eyeY * Float(h))

        let originX = max(0, min(w - patchSize, cx - half))
        let originY = max(0, min(h - patchSize, cy - half))

        let patchRect = CGRect(x: originX, y: originY, width: patchSize, height: patchSize)
        guard let patch = birdCrop.cropping(to: patchRect) else { return nil }

        return LaplacianSharpness.score(image: patch)
    }
}
