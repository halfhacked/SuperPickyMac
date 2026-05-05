import Testing
import Foundation
@testable import SuperPicky

@Suite struct CullingConfigTests {
    /// Remove test-specific keys from UserDefaults so tests start from clean defaults.
    private static let testKeys = [
        "minConfidence", "minAesthetics",
        "burstFps", "burstMinCount", "birdIdConfidence",
        "sharpnessThreshold", "aestheticsThreshold",
    ]

    private func freshConfig() -> CullingConfig {
        for key in Self.testKeys {
            UserDefaults.standard.removeObject(forKey: key)
        }
        return CullingConfig()
    }

    @Test func defaultMinConfidence() {
        let config = freshConfig()
        #expect(config.minConfidence == 0.5)
    }

    @Test func defaultMinAesthetics() {
        let config = freshConfig()
        #expect(config.minAesthetics == 3.5)
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
}
