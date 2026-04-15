import Foundation

/// Calculates picked flags by intersecting the top N% by aesthetics with the top N% by sharpness
/// among 5-star photos. Mirrors superpicky's `_calculate_picked_flags`.
enum PickedFlagCalculator {

    /// Default percentage used when CullingConfig.pickedTopPercentage is not available.
    static let defaultTopPercentage: Int = 25

    /// Returns the set of photo IDs that should be marked as picked.
    ///
    /// Algorithm (matching superpicky):
    /// 1. Filter to 5-star photos only (Mac's highest tier, equivalent to Python's 3-star)
    /// 2. `top_count = max(1, int(count * topPercentage / 100))`
    /// 3. Sort by aesthetics desc -> take top N -> `aestheticsTop`
    /// 4. Sort by sharpness desc -> take top N -> `sharpnessTop`
    /// 5. Return `aestheticsTop ∩ sharpnessTop`
    static func calculatePickedIDs(photos: [Photo], topPercentage: Int) -> Set<UUID> {
        let fiveStarPhotos = photos.filter { $0.starRating == 5 }
        guard !fiveStarPhotos.isEmpty else { return [] }

        let topCount = max(1, Int(Double(fiveStarPhotos.count) * Double(topPercentage) / 100.0))

        // Top N by aesthetics (descending)
        let sortedByAesthetics = fiveStarPhotos.sorted {
            ($0.aestheticsScore ?? 0) > ($1.aestheticsScore ?? 0)
        }
        let aestheticsTopIDs = Set(sortedByAesthetics.prefix(topCount).map(\.id))

        // Top N by sharpness (descending)
        let sortedBySharpness = fiveStarPhotos.sorted {
            ($0.sharpnessScore ?? 0) > ($1.sharpnessScore ?? 0)
        }
        let sharpnessTopIDs = Set(sortedBySharpness.prefix(topCount).map(\.id))

        // Intersection
        return aestheticsTopIDs.intersection(sharpnessTopIDs)
    }
}
