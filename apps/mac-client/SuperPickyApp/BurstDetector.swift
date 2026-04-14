import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Detects burst sequences: consecutive similar photos taken within a time threshold.
///
/// The algorithm runs in four phases, each implemented in `BurstDetectionPhases`:
/// 1. Read precise EXIF timestamps.
/// 2. Group photos by time proximity.
/// 3. Verify groupings with Vision feature-print similarity.
/// 4. Select the best photo within each verified group.
struct BurstDetector: Sendable {
    /// Time threshold in milliseconds — photos closer than this are burst candidates.
    let timeThresholdMs: Double
    /// Minimum photos to form a burst group.
    let minBurstCount: Int
    /// Vision feature print distance threshold — below this, images are considered similar.
    let similarityThreshold: Float

    init(timeThresholdMs: Double = 500, minBurstCount: Int = 2, similarityThreshold: Float = 15.0) {
        self.timeThresholdMs = timeThresholdMs
        self.minBurstCount = minBurstCount
        self.similarityThreshold = similarityThreshold
    }

    /// Detect burst groups from a list of photos (must have filePath and dateCreated).
    func detect(photos: [Photo]) -> [BurstGroup] {
        let timestamped = BurstDetectionPhases.Timestamps.collect(photos: photos)
        guard timestamped.count >= minBurstCount else { return [] }

        let timeGroups = BurstDetectionPhases.TimeGrouping.group(
            timestamped: timestamped,
            timeThresholdMs: timeThresholdMs,
            minBurstCount: minBurstCount
        )

        var verifiedGroups: [BurstGroup] = []
        for group in timeGroups {
            let verified = BurstDetectionPhases.Similarity.verify(
                group: group,
                similarityThreshold: similarityThreshold,
                minBurstCount: minBurstCount
            )
            verifiedGroups.append(contentsOf: verified)
        }

        return verifiedGroups.map { group in
            var g = group
            g.bestPhotoID = BurstDetectionPhases.BestSelection.selectBest(in: g.photos)
            return g
        }
    }

    /// Read DateTimeOriginal + SubSecTimeOriginal from EXIF for millisecond precision.
    func readPreciseTimestamp(filePath: String) -> Double? {
        BurstDetectionPhases.Timestamps.readPrecise(filePath: filePath)
    }
}

/// A group of burst photos.
struct BurstGroup: Identifiable, Sendable {
    let id: UUID
    let photos: [Photo]
    var bestPhotoID: UUID?

    var count: Int { photos.count }
    var bestPhoto: Photo? { photos.first { $0.id == bestPhotoID } }
}
