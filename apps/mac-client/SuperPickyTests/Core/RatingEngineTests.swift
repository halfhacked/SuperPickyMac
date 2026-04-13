import Testing
import Foundation
@testable import SuperPicky

@Suite struct RatingEngineTests {
    let engine = RatingEngine()
    let config = RatingEngine.Config(sharpnessThreshold: 380, aestheticsThreshold: 4.8)

    // MARK: - Early returns (rating 0)

    @Test func noBirdDetected() {
        let result = engine.calculate(detected: false, confidence: 0, config: config)
        #expect(result.rating == 0)
        #expect(result.isPick == false)
    }

    @Test func lowConfidence() {
        let result = engine.calculate(detected: true, confidence: 0.3, config: config)
        #expect(result.rating == 0)
    }

    @Test func veryLowSharpness() {
        let result = engine.calculate(
            detected: true, confidence: 0.9,
            sharpness: 50, aesthetics: 6.0,
            config: config
        )
        #expect(result.rating == 0)
    }

    @Test func veryLowAesthetics() {
        let result = engine.calculate(
            detected: true, confidence: 0.9,
            sharpness: 500, aesthetics: 1.5,
            config: config
        )
        #expect(result.rating == 0)
    }

    // MARK: - Special case

    @Test func allKeypointsHidden() {
        let result = engine.calculate(
            detected: true, confidence: 0.9,
            sharpness: 500, aesthetics: 6.0,
            allKeypointsHidden: true,
            config: config
        )
        #expect(result.rating == 1)
        #expect(result.isPick == false)
    }

    // MARK: - Decision tree: 5 stars (both above threshold)

    @Test func fiveStarBothAboveThreshold() {
        // sharpness=500 >= 380, aesthetics=6.0 >= 4.8
        let result = engine.calculate(
            detected: true, confidence: 0.9,
            sharpness: 500, aesthetics: 6.0,
            bestEyeVisibility: 0.9,
            config: config
        )
        #expect(result.rating == 5)
        #expect(result.isPick == true)
    }

    // MARK: - Decision tree: 4 stars (one above threshold, both above moderate)

    @Test func fourStarSharpAboveThresholdBothAboveModerate() {
        // sharpness=500 >= 380 (threshold), aesthetics=4.0 < 4.8 but >= 3.4 (moderate)
        // adjSharp=500 >= 240 (moderate) ✓
        let result = engine.calculate(
            detected: true, confidence: 0.9,
            sharpness: 500, aesthetics: 4.0,
            bestEyeVisibility: 0.9,
            config: config
        )
        #expect(result.rating == 4)
    }

    @Test func fourStarAestheticsAboveThresholdBothAboveModerate() {
        // sharpness=300 < 380 but >= 240 (moderate), aesthetics=5.0 >= 4.8 (threshold)
        let result = engine.calculate(
            detected: true, confidence: 0.9,
            sharpness: 300, aesthetics: 5.0,
            bestEyeVisibility: 0.9,
            config: config
        )
        #expect(result.rating == 4)
    }

    // MARK: - Decision tree: 3 stars (both above moderate)

    @Test func threeStarBothAboveModerate() {
        // sharpness=300 >= 240 (moderate), aesthetics=4.0 >= 3.4 (moderate)
        // Neither above threshold (300 < 380, 4.0 < 4.8)
        let result = engine.calculate(
            detected: true, confidence: 0.9,
            sharpness: 300, aesthetics: 4.0,
            bestEyeVisibility: 0.9,
            config: config
        )
        #expect(result.rating == 3)
    }

    // MARK: - Decision tree: 2 stars (one above moderate)

    @Test func twoStarSharpAboveModerateOnly() {
        // sharpness=500 >= 240 (moderate), aesthetics=3.0 < 3.4 (moderate)
        let result = engine.calculate(
            detected: true, confidence: 0.9,
            sharpness: 500, aesthetics: 3.0,
            bestEyeVisibility: 0.9,
            config: config
        )
        #expect(result.rating == 2)
    }

    @Test func twoStarAestheticsAboveModerateOnly() {
        // sharpness=200 < 240 (moderate), aesthetics=6.0 >= 3.4 (moderate)
        let result = engine.calculate(
            detected: true, confidence: 0.9,
            sharpness: 200, aesthetics: 6.0,
            bestEyeVisibility: 0.9,
            config: config
        )
        #expect(result.rating == 2)
    }

    // MARK: - Decision tree: 1 star (both below moderate)

    @Test func oneStarBothBelowModerate() {
        // sharpness=200 < 240, aesthetics=3.0 < 3.4
        let result = engine.calculate(
            detected: true, confidence: 0.9,
            sharpness: 200, aesthetics: 3.0,
            bestEyeVisibility: 0.9,
            config: config
        )
        #expect(result.rating == 1)
    }

    // MARK: - Exposure penalty

    @Test func exposurePenalty() {
        // Would be 5 (both above threshold), penalty -1 → 4
        let result = engine.calculate(
            detected: true, confidence: 0.9,
            sharpness: 500, aesthetics: 6.0,
            bestEyeVisibility: 0.9,
            isOverexposed: true,
            config: config
        )
        #expect(result.rating == 4)
        #expect(result.isPick == false)
    }

    @Test func exposurePenaltyFloorAtZero() {
        // Would be 1 (both below moderate), penalty -1 → 0
        let result = engine.calculate(
            detected: true, confidence: 0.9,
            sharpness: 200, aesthetics: 3.0,
            bestEyeVisibility: 0.9,
            isUnderexposed: true,
            config: config
        )
        #expect(result.rating == 0)
    }

    // MARK: - Flying bonus

    @Test func flyingBonus() {
        // sharpness=350*1.2=420 >= 380, aesthetics=4.5*1.1=4.95 >= 4.8 → 5
        let result = engine.calculate(
            detected: true, confidence: 0.9,
            sharpness: 350, aesthetics: 4.5,
            bestEyeVisibility: 0.9,
            isFlying: true,
            config: config
        )
        #expect(result.rating == 5)
        #expect(result.isPick == true)
    }

    // MARK: - isPick

    @Test func isPickOnlyForFiveStar() {
        // 4-star should not be a pick
        let result = engine.calculate(
            detected: true, confidence: 0.9,
            sharpness: 500, aesthetics: 4.0,
            bestEyeVisibility: 0.9,
            config: config
        )
        #expect(result.rating == 4)
        #expect(result.isPick == false)
    }
}
