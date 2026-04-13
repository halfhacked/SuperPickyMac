import Testing
import Foundation
@testable import SuperPicky

@Suite struct RatingEngineTests {
    let engine = RatingEngine()
    let config = RatingEngine.Config(sharpnessThreshold: 380, aestheticsThreshold: 4.8)

    @Test func noBirdDetected() {
        let result = engine.calculate(detected: false, confidence: 0, config: config)
        #expect(result.rating == -1)
    }

    @Test func lowConfidence() {
        let result = engine.calculate(detected: true, confidence: 0.3, config: config)
        #expect(result.rating == 0)
    }

    @Test func allKeypointsHidden() {
        let result = engine.calculate(
            detected: true, confidence: 0.9,
            sharpness: 500, aesthetics: 6.0,
            allKeypointsHidden: true,
            config: config
        )
        #expect(result.rating == 1)
    }

    @Test func threeStarExcellent() {
        let result = engine.calculate(
            detected: true, confidence: 0.9,
            sharpness: 500, aesthetics: 6.0,
            bestEyeVisibility: 0.9,
            config: config
        )
        #expect(result.rating == 3)
    }

    @Test func twoStarSharpOnly() {
        let result = engine.calculate(
            detected: true, confidence: 0.9,
            sharpness: 500, aesthetics: 3.0,
            bestEyeVisibility: 0.9,
            config: config
        )
        #expect(result.rating == 2)
    }

    @Test func twoStarAestheticsOnly() {
        let result = engine.calculate(
            detected: true, confidence: 0.9,
            sharpness: 200, aesthetics: 6.0,
            bestEyeVisibility: 0.9,
            config: config
        )
        #expect(result.rating == 2)
    }

    @Test func oneStarAverage() {
        let result = engine.calculate(
            detected: true, confidence: 0.9,
            sharpness: 200, aesthetics: 3.0,
            bestEyeVisibility: 0.9,
            config: config
        )
        #expect(result.rating == 1)
    }

    @Test func exposurePenalty() {
        let result = engine.calculate(
            detected: true, confidence: 0.9,
            sharpness: 500, aesthetics: 6.0,
            bestEyeVisibility: 0.9,
            isOverexposed: true,
            config: config
        )
        #expect(result.rating == 2)
    }

    @Test func flyingBonus() {
        let result = engine.calculate(
            detected: true, confidence: 0.9,
            sharpness: 350, aesthetics: 4.5,
            bestEyeVisibility: 0.9,
            isFlying: true,
            config: config
        )
        #expect(result.rating == 3)
    }

    @Test func veryLowSharpness() {
        let result = engine.calculate(
            detected: true, confidence: 0.9,
            sharpness: 50, aesthetics: 6.0,
            config: config
        )
        #expect(result.rating == 0)
    }
}
