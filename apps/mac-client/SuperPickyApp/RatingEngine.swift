import Foundation

struct RatingResult: Sendable {
    let rating: Int
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
        isFlying: Bool = false,
        config: Config
    ) -> RatingResult {
        guard detected else {
            return RatingResult(rating: 0, reason: "No bird detected")
        }

        guard confidence >= 0.5 else {
            return RatingResult(rating: 0, reason: "Low confidence: \(confidence)")
        }

        guard sharpness >= Self.minimumSharpness else {
            return RatingResult(rating: 0, reason: "Very low sharpness: \(sharpness)")
        }

        if let aesthetics, aesthetics < Self.minimumAesthetics {
            return RatingResult(rating: 0, reason: "Very low aesthetics: \(aesthetics)")
        }

        if allKeypointsHidden {
            return RatingResult(rating: 1, reason: "All keypoints hidden")
        }

        var adjSharpness = sharpness
        var adjAesthetics = aesthetics ?? 0
        if isFlying {
            adjSharpness *= 1.2
            adjAesthetics *= 1.1
        }

        let moderateSharpness = (Self.minimumSharpness + config.sharpnessThreshold) / 2
        let moderateAesthetics = (Self.minimumAesthetics + config.aestheticsThreshold) / 2

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

        if isOverexposed || isUnderexposed {
            rating = max(0, rating - 1)
        }

        return RatingResult(rating: rating, reason: "Rating: \(rating)")
    }
}
