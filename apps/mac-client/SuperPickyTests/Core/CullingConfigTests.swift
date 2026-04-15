import Testing
import Foundation
@testable import SuperPicky

@Suite struct CullingConfigTests {
    /// Remove test-specific keys from UserDefaults so tests start from clean defaults.
    private static let testKeys = [
        "skillLevel", "minConfidence", "minAesthetics", "pickedTopPercentage",
        "burstFps", "burstMinCount", "birdIdConfidence",
        "sharpnessThreshold", "aestheticsThreshold",
    ]

    private func freshConfig() -> CullingConfig {
        for key in Self.testKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return CullingConfig()
    }

    // MARK: - Skill Level Presets (pure enum, no UserDefaults)

    @Test func beginnerPresetValues() {
        #expect(SkillLevel.beginner.sharpnessThreshold == 300)
        #expect(SkillLevel.beginner.aestheticsThreshold == 4.5)
    }

    @Test func intermediatePresetValues() {
        #expect(SkillLevel.intermediate.sharpnessThreshold == 380)
        #expect(SkillLevel.intermediate.aestheticsThreshold == 4.8)
    }

    @Test func masterPresetValues() {
        #expect(SkillLevel.master.sharpnessThreshold == 520)
        #expect(SkillLevel.master.aestheticsThreshold == 5.5)
    }

    @Test func customPresetReturnsNil() {
        #expect(SkillLevel.custom.sharpnessThreshold == nil)
        #expect(SkillLevel.custom.aestheticsThreshold == nil)
    }

    // MARK: - Skill Level Application

    @Test func applyingSkillLevelUpdatesThresholds() {
        let config = freshConfig()
        config.applySkillLevel(.beginner)
        #expect(config.sharpnessThreshold == 300)
        #expect(config.aestheticsThreshold == 4.5)
        #expect(config.skillLevel == .beginner)
    }

    @Test func applyingMasterSkillLevel() {
        let config = freshConfig()
        config.applySkillLevel(.master)
        #expect(config.sharpnessThreshold == 520)
        #expect(config.aestheticsThreshold == 5.5)
        #expect(config.skillLevel == .master)
    }

    @Test func applyingCustomDoesNotChangeThresholds() {
        let config = freshConfig()
        config.applySkillLevel(.intermediate)
        config.applySkillLevel(.custom)
        // Custom preserves existing thresholds
        #expect(config.sharpnessThreshold == 380)
        #expect(config.aestheticsThreshold == 4.8)
        #expect(config.skillLevel == .custom)
    }

    // MARK: - Default Values

    @Test func defaultMinConfidence() {
        let config = freshConfig()
        #expect(config.minConfidence == 0.5)
    }

    @Test func defaultMinAesthetics() {
        let config = freshConfig()
        #expect(config.minAesthetics == 3.5)
    }

    @Test func defaultPickedTopPercentage() {
        let config = freshConfig()
        #expect(config.pickedTopPercentage == 25)
    }

    @Test func defaultBurstFps() {
        let config = freshConfig()
        #expect(config.burstFps == 10)
    }

    @Test func defaultBurstMinCount() {
        let config = freshConfig()
        #expect(config.burstMinCount == 4)
    }

    @Test func defaultBirdIdConfidence() {
        let config = freshConfig()
        #expect(config.birdIdConfidence == 70)
    }

    @Test func defaultSkillLevel() {
        let config = freshConfig()
        #expect(config.skillLevel == .intermediate)
    }

    // MARK: - Skill Level Enum

    @Test func skillLevelHasAllCases() {
        #expect(SkillLevel.allCases.count == 4)
    }
}
