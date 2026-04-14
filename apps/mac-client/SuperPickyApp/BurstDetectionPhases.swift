import Foundation
import CoreGraphics
import ImageIO
import Vision

/// Pure, stateless implementations of the four phases of burst detection.
///
/// Each phase is exposed as a caseless enum with static methods so it can be
/// exercised in isolation. `BurstDetector` composes these phases; the algorithm,
/// thresholds, and ordering rules live here.
enum BurstDetectionPhases {

    // MARK: - Phase 1: EXIF timestamp reading

    enum Timestamps {
        /// Read `DateTimeOriginal` + `SubSecTimeOriginal` from EXIF for millisecond precision.
        static func readPrecise(filePath: String) -> Double? {
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
            if let subsec = (exif["SubsecTimeOriginal"] ?? exif["SubSecTimeOriginal"]) as? String,
               let subsecFloat = Double("0.\(subsec)") {
                timestamp += subsecFloat
            }

            return timestamp
        }

        /// Build a timestamp-sorted list of photos, dropping any without readable EXIF.
        static func collect(photos: [Photo]) -> [(Photo, Double)] {
            photos.compactMap { photo -> (Photo, Double)? in
                guard let ts = readPrecise(filePath: photo.filePath) else { return nil }
                return (photo, ts)
            }.sorted { $0.1 < $1.1 }
        }
    }

    // MARK: - Phase 2: Time-based grouping

    enum TimeGrouping {
        /// Split a timestamp-sorted list into burst candidates using the time threshold.
        static func group(
            timestamped: [(Photo, Double)],
            timeThresholdMs: Double,
            minBurstCount: Int
        ) -> [BurstGroup] {
            guard !timestamped.isEmpty else { return [] }

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
    }

    // MARK: - Phase 3: Similarity verification

    enum Similarity {
        /// Subdivide a time-based group using Vision feature-print distance.
        static func verify(
            group: BurstGroup,
            similarityThreshold: Float,
            minBurstCount: Int
        ) -> [BurstGroup] {
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

        static func generateFeaturePrint(filePath: String) -> VNFeaturePrintObservation? {
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
    }

    // MARK: - Phase 4: Best photo selection

    enum BestSelection {
        /// Select the best photo by combined sharpness + aesthetics score.
        static func selectBest(in photos: [Photo]) -> UUID? {
            photos.max(by: { score($0) < score($1) })?.id
        }

        static func score(_ photo: Photo) -> Float {
            let sharpness = photo.sharpnessScore ?? 0
            let aesthetics = photo.aestheticsScore ?? 0
            return sharpness * 0.5 + aesthetics * 0.5
        }
    }
}
