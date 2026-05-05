import Foundation
import CoreGraphics
import Accelerate
import SuperPickyInference

/// Head-region sharpness using circular mask around eye + Tenengrad.
/// Ported from superpicky's `_calculate_head_sharpness` in keypoint_detector.py.
struct HeadSharpness {
    static let visibilityThreshold = InferenceConstants.keypointVisibilityThreshold
    static let radiusMultiplier: Float = 1.2
    static let noBeakRadiusRatio: Float = 0.15
    static let lowVisPenalty: Float = 0.8

    /// The eye `score(...)` measures over, and which `SharpnessOverlay`
    /// must draw to honestly visualize the metric.
    struct EyePick {
        let x: Float
        let y: Float
        /// True when neither eye crossed `visibilityThreshold` and we
        /// fell back to the higher-visibility one. The metric applies
        /// `lowVisPenalty` in this case.
        let bothHidden: Bool
    }

    /// Pick the eye `score(...)` would measure over. Shared with
    /// `SharpnessOverlay` so the debug overlay can't disagree with the
    /// metric.
    static func pickEye(
        leftEyeX: Float?, leftEyeY: Float?, leftEyeVis: Float?,
        rightEyeX: Float?, rightEyeY: Float?, rightEyeVis: Float?,
        beakX: Float?, beakY: Float?
    ) -> EyePick? {
        let leftVis = leftEyeVis ?? 0
        let rightVis = rightEyeVis ?? 0
        let bothHidden = leftVis < visibilityThreshold && rightVis < visibilityThreshold
        if bothHidden {
            if leftVis >= rightVis, let x = leftEyeX, let y = leftEyeY {
                return EyePick(x: x, y: y, bothHidden: true)
            }
            if let x = rightEyeX, let y = rightEyeY {
                return EyePick(x: x, y: y, bothHidden: true)
            }
            return nil
        }
        let leftOK = leftVis >= visibilityThreshold
        let rightOK = rightVis >= visibilityThreshold
        // Both eyes visible + beak: pick whichever is further from the beak
        // (matches superpicky's far-eye preference for occlusion robustness).
        if leftOK && rightOK,
           let lx = leftEyeX, let ly = leftEyeY,
           let rx = rightEyeX, let ry = rightEyeY,
           let bx = beakX, let by = beakY {
            let leftDist = hypot(lx - bx, ly - by)
            let rightDist = hypot(rx - bx, ry - by)
            return leftDist >= rightDist
                ? EyePick(x: lx, y: ly, bothHidden: false)
                : EyePick(x: rx, y: ry, bothHidden: false)
        }
        if leftOK, let x = leftEyeX, let y = leftEyeY {
            return EyePick(x: x, y: y, bothHidden: false)
        }
        if let x = rightEyeX, let y = rightEyeY {
            return EyePick(x: x, y: y, bothHidden: false)
        }
        return nil
    }

    /// Compute head-region sharpness of the bird crop using a circular mask centered on the best eye.
    /// Returns nil if crop is too small to measure.
    ///
    /// `segMask`, when supplied, is a `birdCrop.width × birdCrop.height` byte
    /// array (1 = bird, 0 = background) and is intersected with the head
    /// circle, matching superpicky's
    /// `cv2.bitwise_and(circle_mask, seg_mask)` in
    /// `core/keypoint_detector.py:_calculate_head_sharpness`.
    ///
    /// `birdBboxSize`, when supplied, is the `(width, height)` of the YOLO
    /// detection bbox in inference-image pixels. It's used as the no-beak
    /// fallback radius (`max(w, h) × 0.15`), preferred over the
    /// `birdCrop` size which is ~15% larger because of the 1.15× smart-
    /// square padding. Mirrors the `box` branch in superpicky's
    /// `_calculate_head_sharpness:248-252,283-290`.
    static func score(
        birdCrop: CGImage,
        leftEyeX: Float?, leftEyeY: Float?, leftEyeVis: Float?,
        rightEyeX: Float?, rightEyeY: Float?, rightEyeVis: Float?,
        beakX: Float?, beakY: Float?, beakVis: Float?,
        segMask: [UInt8]? = nil,
        birdBboxSize: (width: Int, height: Int)? = nil
    ) -> Float? {
        let w = birdCrop.width
        let h = birdCrop.height
        guard w > 10 && h > 10 else { return nil }

        guard let pick = pickEye(
            leftEyeX: leftEyeX, leftEyeY: leftEyeY, leftEyeVis: leftEyeVis,
            rightEyeX: rightEyeX, rightEyeY: rightEyeY, rightEyeVis: rightEyeVis,
            beakX: beakX, beakY: beakY
        ) else { return nil }

        let beakVisible = (beakVis ?? 0) >= visibilityThreshold
        let eyePx = (Int(pick.x * Float(w)), Int(pick.y * Float(h)))

        // Compute radius. Three-branch fallback matches superpicky's
        // _calculate_head_sharpness:
        //   1. eye-beak distance × 1.2 (when beak is visible)
        //   2. YOLO bbox max-side × 0.15 (when bbox is provided)
        //   3. bird-crop max-side × 0.15 (last-resort fallback;
        //      bird-crop is ~15% larger than the bbox because of the
        //      1.15× smart-square padding, so this only matches Python
        //      when both beak and bbox are absent)
        var radius: Int
        if beakVisible, let bx = beakX, let by = beakY {
            let beakPx = (Int(bx * Float(w)), Int(by * Float(h)))
            let dist = hypot(Float(eyePx.0 - beakPx.0), Float(eyePx.1 - beakPx.1))
            radius = Int(dist * radiusMultiplier)
        } else if let box = birdBboxSize {
            radius = Int(Float(max(box.width, box.height)) * noBeakRadiusRatio)
        } else {
            radius = Int(Float(max(w, h)) * noBeakRadiusRatio)
        }
        radius = max(10, min(radius, min(w, h) / 2))

        // Compute masked Tenengrad — intersect the head circle with the
        // YOLO segmentation mask when available so background pixels (sky,
        // foliage, water) don't contribute their gradient² to the average.
        let score = TenengradSharpness.maskedScore(
            image: birdCrop,
            centerX: eyePx.0, centerY: eyePx.1,
            radius: radius,
            extraMask: segMask
        )

        return pick.bothHidden ? score * lowVisPenalty : score
    }
}
