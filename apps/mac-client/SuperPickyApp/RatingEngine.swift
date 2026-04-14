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
            return RatingResult(rating: 0, isPick: false, reason: "No bird detected")
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

        let sharpnessTier = Self.tier(
            value: adjSharpness,
            minimum: Self.minimumSharpness,
            threshold: config.sharpnessThreshold
        )
        let aestheticsTier = Self.tier(
            value: adjAesthetics,
            minimum: Self.minimumAesthetics,
            threshold: config.aestheticsThreshold
        )
        var rating = Self.starRating(sharpness: sharpnessTier, aesthetics: aestheticsTier)

        if isOverexposed || isUnderexposed {
            rating = max(0, rating - 1)
        }

        let isPick = rating == 5

        return RatingResult(rating: rating, isPick: isPick, reason: "Rating: \(rating)")
    }

    // MARK: - Decision table

    /// Each input dimension is bucketed into a tier; the (sharpness, aesthetics)
    /// tier pair then maps to a star rating via an exhaustive switch. This keeps
    /// the decision boundaries explicit and forces the compiler to flag any
    /// missing combination.
    private enum Tier {
        case rejected   // below moderate midpoint
        case moderate   // at/above moderate midpoint, below configured threshold
        case high       // at/above configured threshold
    }

    // Fixed minimums (sharpness 100, aesthetics 2.0) anchor the moderate midpoint
    // halfway between the floor and the configured threshold.
    private static func tier(value: Float, minimum: Float, threshold: Float) -> Tier {
        if value >= threshold { return .high }
        let moderate = (minimum + threshold) / 2
        if value >= moderate { return .moderate }
        return .rejected
    }

    private static func starRating(sharpness: Tier, aesthetics: Tier) -> Int {
        switch (sharpness, aesthetics) {
        case (.high,     .high):     return 5
        case (.high,     .moderate): return 4
        case (.moderate, .high):     return 4
        case (.moderate, .moderate): return 3
        case (.high,     .rejected): return 2
        case (.rejected, .high):     return 2
        case (.moderate, .rejected): return 2
        case (.rejected, .moderate): return 2
        case (.rejected, .rejected): return 1
        }
    }
}
