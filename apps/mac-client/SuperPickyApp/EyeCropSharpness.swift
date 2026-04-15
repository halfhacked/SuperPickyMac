import Foundation
import CoreGraphics
import Accelerate

/// Head-region sharpness using circular mask around eye + Tenengrad.
/// Ported from superpicky's `_calculate_head_sharpness` in keypoint_detector.py.
struct HeadSharpness {
    static let visibilityThreshold: Float = 0.3
    static let radiusMultiplier: Float = 1.2
    static let noBeakRadiusRatio: Float = 0.15
    static let lowVisPenalty: Float = 0.8

    /// Compute head-region sharpness of the bird crop using a circular mask centered on the best eye.
    /// Returns nil if crop is too small to measure.
    static func score(
        birdCrop: CGImage,
        leftEyeX: Float?, leftEyeY: Float?, leftEyeVis: Float?,
        rightEyeX: Float?, rightEyeY: Float?, rightEyeVis: Float?,
        beakX: Float?, beakY: Float?, beakVis: Float?
    ) -> Float? {
        let w = birdCrop.width
        let h = birdCrop.height
        guard w > 10 && h > 10 else { return nil }

        let leftVis = leftEyeVis ?? 0
        let rightVis = rightEyeVis ?? 0
        let beakVisible = (beakVis ?? 0) >= visibilityThreshold

        // Both eyes below visibility threshold: fallback with penalty
        let bothHidden = leftVis < visibilityThreshold && rightVis < visibilityThreshold
        let eye: (Float, Float)
        if bothHidden {
            // Use whichever eye has higher visibility as fallback
            if leftVis >= rightVis, let x = leftEyeX, let y = leftEyeY {
                eye = (x, y)
            } else if let x = rightEyeX, let y = rightEyeY {
                eye = (x, y)
            } else {
                return nil
            }
        } else {
            // Pick eye further from beak (matches superpicky logic)
            let leftOK = leftVis >= visibilityThreshold
            let rightOK = rightVis >= visibilityThreshold
            if leftOK && rightOK, let lx = leftEyeX, let ly = leftEyeY,
               let rx = rightEyeX, let ry = rightEyeY,
               let bx = beakX, let by = beakY {
                let leftDist = hypot(lx - bx, ly - by)
                let rightDist = hypot(rx - bx, ry - by)
                eye = leftDist >= rightDist ? (lx, ly) : (rx, ry)
            } else if leftOK, let x = leftEyeX, let y = leftEyeY {
                eye = (x, y)
            } else if let x = rightEyeX, let y = rightEyeY {
                eye = (x, y)
            } else {
                return nil
            }
        }

        let eyePx = (Int(eye.0 * Float(w)), Int(eye.1 * Float(h)))

        // Compute radius from eye-beak distance × 1.2, or 15% of crop if no beak
        var radius: Int
        if beakVisible, let bx = beakX, let by = beakY {
            let beakPx = (Int(bx * Float(w)), Int(by * Float(h)))
            let dist = hypot(Float(eyePx.0 - beakPx.0), Float(eyePx.1 - beakPx.1))
            radius = Int(dist * radiusMultiplier)
        } else {
            radius = Int(Float(max(w, h)) * noBeakRadiusRatio)
        }
        radius = max(10, min(radius, min(w, h) / 2))

        // Compute masked Tenengrad
        let score = TenengradSharpness.maskedScore(
            image: birdCrop,
            centerX: eyePx.0, centerY: eyePx.1,
            radius: radius
        )

        return bothHidden ? score * lowVisPenalty : score
    }
}
