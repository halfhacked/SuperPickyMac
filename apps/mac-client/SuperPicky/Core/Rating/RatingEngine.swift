import Foundation

struct RatingResult: Sendable {
    let rating: Int
    let isPick: Bool
    let reason: String
}

struct RatingEngine: Sendable {
    static let minimumSharpness: Float = 100
    static let minimumAesthetics: Float = 2.0

    struct Config: Sendable {
        let sharpnessThreshold: Float
        let aestheticsThreshold: Float
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
            return RatingResult(rating: -1, isPick: false, reason: "No bird detected")
        }

        guard confidence >= 0.5 else {
            return RatingResult(rating: 0, isPick: false, reason: "Low confidence: \(confidence)")
        }

        guard sharpness >= Self.minimumSharpness else {
            return RatingResult(rating: 0, isPick: false, reason: "Very low sharpness: \(sharpness)")
        }

        if let aesthetics, aesthetics < Self.minimumAesthetics {
            return RatingResult(rating: 0, isPick: false, reason: "Very low aesthetics: \(aesthetics)")
        }

        if allKeypointsHidden {
            return RatingResult(rating: 1, isPick: false, reason: "All keypoints hidden")
        }

        var adjSharpness = sharpness * focusSharpnessWeight
        var adjAesthetics = (aesthetics ?? 0) * focusAestheticsWeight
        if isFlying {
            adjSharpness *= 1.2
            adjAesthetics *= 1.1
        }

        var rating: Int
        let sharpHigh = adjSharpness >= config.sharpnessThreshold
        let aestheticsHigh = adjAesthetics >= config.aestheticsThreshold

        if sharpHigh && aestheticsHigh {
            rating = 3
        } else if sharpHigh || aestheticsHigh {
            rating = 2
        } else {
            rating = 1
        }

        if isOverexposed || isUnderexposed {
            rating = max(0, rating - 1)
        }

        let isPick = rating == 3 && sharpHigh && aestheticsHigh

        return RatingResult(rating: rating, isPick: isPick, reason: "Rating: \(rating)")
    }
}
