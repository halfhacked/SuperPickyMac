import Foundation

/// Pure conversion from a `Photo` + `RatingEngine.Config` into the predicted
/// star rating. Used by the threshold calibrator's preview and isolated here
/// so the keypoint-visibility / exposure-string translation is unit-testable
/// without spinning up a SwiftUI view.
enum PhotoRatingPredictor {

    /// Keypoint visibility below this threshold (in every keypoint) is
    /// treated as "all keypoints hidden", which maps to a 1-star floor
    /// in `RatingEngine`.
    static let keypointHiddenThreshold: Float = 0.3

    /// Returns the predicted rating, or `nil` when there's no photo or
    /// no bird detection confidence to feed the engine.
    static func predict(photo: Photo?, config: RatingEngine.Config) -> Int? {
        guard let photo, let confidence = photo.birdConfidence else { return nil }
        return RatingEngine().calculate(
            detected: true,
            confidence: confidence,
            sharpness: photo.sharpnessScore ?? 0,
            aesthetics: photo.aestheticsScore,
            allKeypointsHidden: allKeypointsHidden(photo),
            isOverexposed: photo.exposureStatus == ExposureStatus.overexposed.rawValue,
            isUnderexposed: photo.exposureStatus == ExposureStatus.underexposed.rawValue,
            isFlying: photo.isFlying,
            config: config
        ).rating
    }

    /// Every keypoint visibility (nil treated as 0) falls below the
    /// hidden threshold. Any one keypoint being visible keeps the photo
    /// in the normal decision tree.
    static func allKeypointsHidden(_ photo: Photo) -> Bool {
        (photo.leftEyeVis ?? 0) < keypointHiddenThreshold
            && (photo.rightEyeVis ?? 0) < keypointHiddenThreshold
            && (photo.beakVis ?? 0) < keypointHiddenThreshold
    }
}
