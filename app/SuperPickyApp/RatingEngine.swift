import Foundation

struct RatingResult: Sendable {
    let rating: Int
    let reason: String
}

struct RatingEngine: Sendable {

    struct Config: Sendable {
        let sharpnessThreshold: Float
        let aestheticsThreshold: Float
        let minConfidence: Float
        let minSharpness: Float
        let minAesthetics: Float

        init(sharpnessThreshold: Float, aestheticsThreshold: Float,
             minConfidence: Float = 0.5, minSharpness: Float = 100, minAesthetics: Float = 3.5) {
            self.sharpnessThreshold = sharpnessThreshold
            self.aestheticsThreshold = aestheticsThreshold
            self.minConfidence = minConfidence
            self.minSharpness = minSharpness
            self.minAesthetics = minAesthetics
        }
    }

    func calculate(
        detected: Bool,
        confidence: Float,
        sharpness: Float = 0,
        aesthetics: Float? = nil,
        allKeypointsHidden: Bool = false,
        bestEyeVisibility: Float = 1.0,
        isOverexposed: Bool = false,
        isUnderexposed: Bool = false,
        focusSharpnessWeight: Float = 1.0,
        focusAestheticsWeight: Float = 1.0,
        isFlying: Bool = false,
        config: Config
    ) -> RatingResult {
        guard detected else {
            return RatingResult(rating: 0, reason: "No bird detected")
        }

        guard confidence >= config.minConfidence else {
            return RatingResult(rating: 0, reason: "Low confidence: \(confidence)")
        }

        if allKeypointsHidden {
            return RatingResult(rating: 1, reason: "All keypoints hidden")
        }

        guard sharpness >= config.minSharpness else {
            return RatingResult(rating: 0, reason: "Very low sharpness: \(sharpness)")
        }

        if let aesthetics, aesthetics < config.minAesthetics {
            return RatingResult(rating: 0, reason: "Very low aesthetics: \(aesthetics)")
        }

        // Apply focus weights first, then flying bonus (matches superpicky order)
        var adjSharpness = sharpness * focusSharpnessWeight
        var adjAesthetics = (aesthetics ?? 0) * focusAestheticsWeight
        if isFlying {
            adjSharpness *= 1.2
            adjAesthetics *= 1.1
        }

        let moderateSharpness = (config.minSharpness + config.sharpnessThreshold) / 2
        let moderateAesthetics = (config.minAesthetics + config.aestheticsThreshold) / 2

        let sharpAboveThreshold = adjSharpness >= config.sharpnessThreshold
        let aestheticsAboveThreshold = adjAesthetics >= config.aestheticsThreshold
        let sharpAboveModerate = adjSharpness >= moderateSharpness
        let aestheticsAboveModerate = adjAesthetics >= moderateAesthetics

        var rating: Int

        if sharpAboveThreshold && aestheticsAboveThreshold {
            rating = 5
        } else if (sharpAboveThreshold || aestheticsAboveThreshold) && (sharpAboveModerate && aestheticsAboveModerate) {
            rating = 4
        } else if sharpAboveModerate && aestheticsAboveModerate {
            rating = 3
        } else if sharpAboveModerate || aestheticsAboveModerate {
            rating = 2
        } else {
            rating = 1
        }

        // Eye visibility degradation: max(0.5, min(1.0, bestEyeVisibility * 2))
        // visibility 0.5+ → weight 1.0, visibility 0.25 → weight 0.5
        let visibilityWeight = max(0.5, min(1.0, bestEyeVisibility * 2))
        if visibilityWeight < 1.0 {
            rating = Int((Float(rating) * visibilityWeight).rounded())
        }

        if isOverexposed || isUnderexposed {
            rating = max(0, rating - 1)
        }

        // Build reason
        var parts: [String] = []
        if focusSharpnessWeight > 1.0 {
            parts.append("focus:best")
        } else if focusSharpnessWeight >= 0.9 {
            parts.append("focus:good")
        } else if focusSharpnessWeight >= 0.7 {
            parts.append("focus:fair")
        } else {
            parts.append("focus:miss")
        }
        if visibilityWeight < 1.0 {
            parts.append("vis:\(String(format: "%.2f", bestEyeVisibility))")
        }
        if isOverexposed { parts.append("overexposed") }
        if isUnderexposed { parts.append("underexposed") }
        if isFlying { parts.append("flying") }

        return RatingResult(rating: rating, reason: parts.joined(separator: " "))
    }
}
