import Testing
import Foundation
@testable import SuperPicky

@Suite struct PhotoRatingPredictorTests {

    private let config = RatingEngine.Config(sharpnessThreshold: 380, aestheticsThreshold: 4.8)

    private func photo(
        birdConfidence: Float? = 0.9,
        sharpness: Float? = 500,
        aesthetics: Float? = 6.0,
        leftEyeVis: Float? = 0.9,
        rightEyeVis: Float? = 0.9,
        beakVis: Float? = 0.9,
        isFlying: Bool = false,
        exposureStatus: String? = nil
    ) -> Photo {
        var p = Photo(filename: "x.jpg", filePath: "/tmp/x.jpg", folderPath: "/tmp")
        p.birdConfidence = birdConfidence
        p.sharpnessScore = sharpness
        p.aestheticsScore = aesthetics
        p.leftEyeVis = leftEyeVis
        p.rightEyeVis = rightEyeVis
        p.beakVis = beakVis
        p.isFlying = isFlying
        p.exposureStatus = exposureStatus
        return p
    }

    // MARK: - nil paths

    @Test func returnsNilWhenPhotoIsNil() {
        #expect(PhotoRatingPredictor.predict(photo: nil, config: config) == nil)
    }

    @Test func returnsNilWhenBirdConfidenceIsMissing() {
        let p = photo(birdConfidence: nil)
        #expect(PhotoRatingPredictor.predict(photo: p, config: config) == nil)
    }

    // MARK: - allKeypointsHidden gate

    @Test func allKeypointsHiddenWhenEveryVisibilityBelowThreshold() {
        let p = photo(leftEyeVis: 0.1, rightEyeVis: 0.2, beakVis: 0.29)
        #expect(PhotoRatingPredictor.allKeypointsHidden(p) == true)
    }

    @Test func allKeypointsHiddenFalseWhenAnyKeypointVisible() {
        // Left eye visible — not all hidden.
        let a = photo(leftEyeVis: 0.5, rightEyeVis: 0.1, beakVis: 0.1)
        #expect(PhotoRatingPredictor.allKeypointsHidden(a) == false)
        // Beak visible.
        let b = photo(leftEyeVis: 0.1, rightEyeVis: 0.1, beakVis: 0.9)
        #expect(PhotoRatingPredictor.allKeypointsHidden(b) == false)
    }

    @Test func allKeypointsHiddenTreatsNilVisibilityAsZero() {
        // All nil visibilities → all < 0.3 → hidden.
        let p = photo(leftEyeVis: nil, rightEyeVis: nil, beakVis: nil)
        #expect(PhotoRatingPredictor.allKeypointsHidden(p) == true)
    }

    @Test func allKeypointsHiddenExactlyAtThresholdIsNotHidden() {
        // 0.3 is the boundary — `< 0.3` is strict, so 0.3 counts as visible.
        let p = photo(leftEyeVis: 0.3, rightEyeVis: 0.1, beakVis: 0.1)
        #expect(PhotoRatingPredictor.allKeypointsHidden(p) == false)
    }

    @Test func predictCollapsesToOneStarWhenAllKeypointsHidden() {
        // RatingEngine: allKeypointsHidden short-circuits to rating 1.
        let p = photo(
            birdConfidence: 0.95,
            sharpness: 500,
            aesthetics: 6.0,
            leftEyeVis: 0.0, rightEyeVis: 0.0, beakVis: 0.0
        )
        #expect(PhotoRatingPredictor.predict(photo: p, config: config) == 1)
    }

    // MARK: - exposure-status string mapping

    @Test func mapsOverexposedStringToPenalty() {
        let p = photo(exposureStatus: ExposureStatus.overexposed.rawValue)
        // 5-star photo -1 for over/under exposed = 4.
        #expect(PhotoRatingPredictor.predict(photo: p, config: config) == 4)
    }

    @Test func mapsUnderexposedStringToPenalty() {
        let p = photo(exposureStatus: ExposureStatus.underexposed.rawValue)
        #expect(PhotoRatingPredictor.predict(photo: p, config: config) == 4)
    }

    @Test func nonExposureStatusStringLeavesRatingUnchanged() {
        let p = photo(exposureStatus: "something-else")
        #expect(PhotoRatingPredictor.predict(photo: p, config: config) == 5)
    }

    @Test func nilExposureStatusLeavesRatingUnchanged() {
        let p = photo(exposureStatus: nil)
        #expect(PhotoRatingPredictor.predict(photo: p, config: config) == 5)
    }

    // MARK: - passthrough of photo fields

    @Test func nilSharpnessTreatedAsZeroAndFailsMinimum() {
        // RatingEngine's `minSharpness` default is 100; sharpness 0 is below.
        let p = photo(sharpness: nil)
        #expect(PhotoRatingPredictor.predict(photo: p, config: config) == 0)
    }

    @Test func flyingBonusPassedThroughToEngine() {
        // sharpness=350*1.2=420 >= 380, aesthetics=4.5*1.1=4.95 >= 4.8 → 5
        let p = photo(sharpness: 350, aesthetics: 4.5, isFlying: true)
        #expect(PhotoRatingPredictor.predict(photo: p, config: config) == 5)
    }

    @Test func fullDefaultPhotoPredictsFiveStars() {
        // Sanity: the helper in this file produces a 5-star photo by default.
        let p = photo()
        #expect(PhotoRatingPredictor.predict(photo: p, config: config) == 5)
    }
}
