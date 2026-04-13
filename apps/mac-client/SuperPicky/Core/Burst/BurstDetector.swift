import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Detects burst sequences: consecutive similar photos taken within a time threshold.
struct BurstDetector: Sendable {
    /// Time threshold in milliseconds — photos closer than this are burst candidates.
    let timeThresholdMs: Double
    /// Minimum photos to form a burst group.
    let minBurstCount: Int
    /// Vision feature print distance threshold — below this, images are considered similar.
    let similarityThreshold: Float

    init(timeThresholdMs: Double = 250, minBurstCount: Int = 3, similarityThreshold: Float = 15.0) {
        self.timeThresholdMs = timeThresholdMs
        self.minBurstCount = minBurstCount
        self.similarityThreshold = similarityThreshold
    }

    /// Detect burst groups from a list of photos (must have filePath and dateCreated).
    func detect(photos: [Photo]) -> [BurstGroup] {
        // 1. Read precise timestamps from EXIF
        let timestamped = photos.compactMap { photo -> (Photo, Double)? in
            guard let ts = readPreciseTimestamp(filePath: photo.filePath) else { return nil }
            return (photo, ts)
        }.sorted { $0.1 < $1.1 }

        guard timestamped.count >= minBurstCount else { return [] }

        // 2. Group by time proximity
        var timeGroups = groupByTime(timestamped)

        // 3. Verify with image similarity (Vision feature prints)
        var verifiedGroups: [BurstGroup] = []
        for group in timeGroups {
            let verified = verifyWithSimilarity(group)
            verifiedGroups.append(contentsOf: verified)
        }

        // 4. Select best photo per group
        return verifiedGroups.map { group in
            var g = group
            g.bestPhotoID = selectBest(in: g.photos)
            return g
        }
    }

    // MARK: - Phase 1: EXIF timestamp reading

    /// Read DateTimeOriginal + SubSecTimeOriginal from EXIF for millisecond precision.
    func readPreciseTimestamp(filePath: String) -> Double? {
        let url = URL(fileURLWithPath: filePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any],
              let exif = properties["{Exif}"] as? [String: Any],
              let dateStr = exif["DateTimeOriginal"] as? String else {
            return nil
        }

        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.timeZone = TimeZone.current

        guard let date = formatter.date(from: dateStr) else { return nil }
        var timestamp = date.timeIntervalSince1970

        // Add subsecond precision if available
        if let subsec = exif["SubSecTimeOriginal"] as? String,
           let subsecFloat = Double("0.\(subsec)") {
            timestamp += subsecFloat
        }

        return timestamp
    }

    // MARK: - Phase 2: Time-based grouping

    private func groupByTime(_ timestamped: [(Photo, Double)]) -> [BurstGroup] {
        var groups: [BurstGroup] = []
        var currentPhotos: [Photo] = [timestamped[0].0]
        var currentTimestamps: [Double] = [timestamped[0].1]

        for i in 1..<timestamped.count {
            let timeDiffMs = (timestamped[i].1 - currentTimestamps.last!) * 1000

            if timeDiffMs <= timeThresholdMs {
                currentPhotos.append(timestamped[i].0)
                currentTimestamps.append(timestamped[i].1)
            } else {
                if currentPhotos.count >= minBurstCount {
                    groups.append(BurstGroup(
                        id: UUID(),
                        photos: currentPhotos,
                        bestPhotoID: nil
                    ))
                }
                currentPhotos = [timestamped[i].0]
                currentTimestamps = [timestamped[i].1]
            }
        }

        // Don't forget the last group
        if currentPhotos.count >= minBurstCount {
            groups.append(BurstGroup(
                id: UUID(),
                photos: currentPhotos,
                bestPhotoID: nil
            ))
        }

        return groups
    }

    // MARK: - Phase 3: Similarity verification

    private func verifyWithSimilarity(_ group: BurstGroup) -> [BurstGroup] {
        let photos = group.photos
        guard photos.count >= 2 else { return [group] }

        // Generate feature prints for all photos
        var featurePrints: [VNFeaturePrintObservation?] = []
        for photo in photos {
            featurePrints.append(generateFeaturePrint(filePath: photo.filePath))
        }

        // Split groups where similarity breaks
        var subGroups: [BurstGroup] = []
        var currentPhotos: [Photo] = [photos[0]]

        for i in 1..<photos.count {
            let similar: Bool
            if let fp1 = featurePrints[i - 1], let fp2 = featurePrints[i] {
                var distance: Float = 0
                try? fp1.computeDistance(&distance, to: fp2)
                similar = distance <= similarityThreshold
            } else {
                similar = true // If we can't compute, assume similar (time-based grouping already filtered)
            }

            if similar {
                currentPhotos.append(photos[i])
            } else {
                if currentPhotos.count >= minBurstCount {
                    subGroups.append(BurstGroup(id: UUID(), photos: currentPhotos, bestPhotoID: nil))
                }
                currentPhotos = [photos[i]]
            }
        }

        if currentPhotos.count >= minBurstCount {
            subGroups.append(BurstGroup(id: UUID(), photos: currentPhotos, bestPhotoID: nil))
        }

        return subGroups
    }

    private func generateFeaturePrint(filePath: String) -> VNFeaturePrintObservation? {
        let url = URL(fileURLWithPath: filePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceThumbnailMaxPixelSize: 256,
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
              ] as CFDictionary) else {
            return nil
        }

        let request = VNGenerateImageFeaturePrintRequest()
        let handler = VNImageRequestHandler(cgImage: cgImage)
        try? handler.perform([request])
        return request.results?.first as? VNFeaturePrintObservation
    }

    // MARK: - Phase 4: Best photo selection

    /// Select the best photo by combined sharpness + aesthetics score.
    private func selectBest(in photos: [Photo]) -> UUID? {
        photos.max(by: { score($0) < score($1) })?.id
    }

    private func score(_ photo: Photo) -> Float {
        let sharpness = photo.sharpnessScore ?? 0
        let aesthetics = photo.aestheticsScore ?? 0
        return sharpness * 0.5 + aesthetics * 0.5
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
