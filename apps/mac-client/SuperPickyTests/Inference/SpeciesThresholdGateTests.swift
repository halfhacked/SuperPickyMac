import Testing
import Foundation
@testable import SuperPicky
@testable import SuperPickyInference

@Suite("Species top-1 confidence gate")
struct SpeciesThresholdGateTests {
    /// The gate converts `InferenceConstants` percent-scale thresholds
    /// (80/90) to the 0–1 softmax-probability scale the comparison
    /// actually runs on. A drift on either side silently mislabels low
    /// confidence predictions.
    @Test("Global path uses globalSpeciesThreshold/100")
    func globalThresholdNormalizedToProbability() {
        let threshold = CoreMLInferenceClient.top1ConfidenceThreshold(usedRegional: false)
        #expect(threshold == InferenceConstants.globalSpeciesThreshold / 100)
        #expect(threshold == 0.9)
    }

    @Test("Regional path uses regionalSpeciesThreshold/100")
    func regionalThresholdNormalizedToProbability() {
        let threshold = CoreMLInferenceClient.top1ConfidenceThreshold(usedRegional: true)
        #expect(threshold == InferenceConstants.regionalSpeciesThreshold / 100)
        #expect(threshold == 0.8)
    }

    /// A probability just under the regional threshold must be rejected
    /// by the gate, while one just over must pass. These are the
    /// boundary cases users actually hit — `prob == 0.47` stays nil in
    /// `speciesCommonName`, `prob == 0.91` becomes an identification.
    @Test("A 0.79 regional-path probability is below the gate")
    func regionalGateRejectsBelow() {
        let threshold = CoreMLInferenceClient.top1ConfidenceThreshold(usedRegional: true)
        #expect(0.79 < threshold)
    }

    @Test("A 0.81 regional-path probability clears the gate")
    func regionalGateAcceptsAbove() {
        let threshold = CoreMLInferenceClient.top1ConfidenceThreshold(usedRegional: true)
        #expect(Float(0.81) > threshold)
    }

    @Test("A 0.89 global-path probability is below the gate")
    func globalGateRejectsBelow() {
        let threshold = CoreMLInferenceClient.top1ConfidenceThreshold(usedRegional: false)
        #expect(0.89 < threshold)
    }

    @Test("A 0.91 global-path probability clears the gate")
    func globalGateAcceptsAbove() {
        let threshold = CoreMLInferenceClient.top1ConfidenceThreshold(usedRegional: false)
        #expect(Float(0.91) > threshold)
    }
}
