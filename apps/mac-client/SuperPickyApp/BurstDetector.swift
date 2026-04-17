import Foundation
import CoreGraphics
import ImageIO
import Vision
import Accelerate

/// Which algorithm to use for burst similarity verification.
enum BurstSimilarityMethod: Sendable {
    /// DCT-based perceptual hash (8x8), matching superpicky's imagehash.phash.
    /// Threshold is hamming distance (0 = identical, 64 = maximally different).
    case dctPHash
    /// Vision framework neural feature print.
    /// Threshold is VNFeaturePrint euclidean distance.
    case visionFeaturePrint
}

/// Detects burst sequences: consecutive similar photos taken within a time threshold.
struct BurstDetector: Sendable {
    /// Time threshold in milliseconds — photos closer than this are burst candidates.
    let timeThresholdMs: Double
    /// Minimum photos to form a burst group.
    let minBurstCount: Int
    /// Similarity threshold — meaning depends on `similarityMethod`:
    /// - `.dctPHash`: max hamming distance (default 12, matching superpicky's PHASH_THRESHOLD)
    /// - `.visionFeaturePrint`: max feature print distance (default 15.0)
    let similarityThreshold: Float
    /// Which similarity algorithm to use for verification.
    let similarityMethod: BurstSimilarityMethod

    private nonisolated(unsafe) static let exifDateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
        formatter.locale = Locale(identifier: "en_US_POSIX")  // required for format strings
        formatter.timeZone = TimeZone.current
        return formatter
    }()

    init(
        timeThresholdMs: Double = 500,
        minBurstCount: Int = 2,
        similarityThreshold: Float = 12,
        similarityMethod: BurstSimilarityMethod = .dctPHash
    ) {
        self.timeThresholdMs = timeThresholdMs
        self.minBurstCount = minBurstCount
        self.similarityThreshold = similarityThreshold
        self.similarityMethod = similarityMethod
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

        let formatter = Self.exifDateFormatter

        guard let date = formatter.date(from: dateStr) else { return nil }
        var timestamp = date.timeIntervalSince1970

        // Add subsecond precision if available
        if let subsec = (exif["SubsecTimeOriginal"] ?? exif["SubSecTimeOriginal"]) as? String,
           let subsecFloat = Double("0.\(subsec)") {
            timestamp += subsecFloat
        }

        return timestamp
    }

    /// Read EXIF `{Exif}` sub-dict + GPS sub-dict from a single CGImageSource
    /// open. Used by the pipeline's pre-pass to get both the precise
    /// timestamp (for burst ordering) and the GPS coord (for geocoder
    /// pre-warm) without opening the file twice.
    static func readPreciseTimestampAndGPS(
        filePath: String
    ) -> (timestamp: Double?, lat: Double?, lon: Double?) {
        let url = URL(fileURLWithPath: filePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [String: Any] else {
            return (nil, nil, nil)
        }

        var timestamp: Double?
        if let exif = properties["{Exif}"] as? [String: Any],
           let dateStr = exif["DateTimeOriginal"] as? String,
           let date = exifDateFormatter.date(from: dateStr) {
            var ts = date.timeIntervalSince1970
            if let subsec = (exif["SubsecTimeOriginal"] ?? exif["SubSecTimeOriginal"]) as? String,
               let subsecFloat = Double("0.\(subsec)") {
                ts += subsecFloat
            }
            timestamp = ts
        }

        var lat: Double?
        var lon: Double?
        if let gpsKey = properties[kCGImagePropertyGPSDictionary as String] as? [String: Any],
           var latVal = gpsKey[kCGImagePropertyGPSLatitude as String] as? Double,
           var lonVal = gpsKey[kCGImagePropertyGPSLongitude as String] as? Double {
            if let latRef = gpsKey[kCGImagePropertyGPSLatitudeRef as String] as? String,
               latRef.uppercased() == "S" { latVal = -latVal }
            if let lonRef = gpsKey[kCGImagePropertyGPSLongitudeRef as String] as? String,
               lonRef.uppercased() == "W" { lonVal = -lonVal }
            if (-90.0...90.0).contains(latVal), (-180.0...180.0).contains(lonVal),
               !(abs(latVal) < 1e-6 && abs(lonVal) < 1e-6) {
                lat = latVal
                lon = lonVal
            }
        }

        return (timestamp, lat, lon)
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
        switch similarityMethod {
        case .dctPHash:
            return verifyWithPHash(group)
        case .visionFeaturePrint:
            return verifyWithFeaturePrint(group)
        }
    }

    // MARK: - pHash verification (matches superpicky's imagehash.phash)

    private func verifyWithPHash(_ group: BurstGroup) -> [BurstGroup] {
        let photos = group.photos
        guard photos.count >= 2 else { return [group] }

        // Compute pHash for all photos
        let hashes: [UInt64?] = photos.map { computePHash(filePath: $0.filePath) }

        return splitByDistance(photos: photos, hashes: hashes)
    }

    /// Split a group at consecutive pairs whose distance exceeds the threshold.
    /// Shared logic for both pHash and feature-print paths.
    private func splitByDistance(photos: [Photo], hashes: [UInt64?]) -> [BurstGroup] {
        var subGroups: [BurstGroup] = []
        var currentPhotos: [Photo] = [photos[0]]

        for i in 1..<photos.count {
            let similar: Bool
            if let h1 = hashes[i - 1], let h2 = hashes[i] {
                let distance = Self.hammingDistance(h1, h2)
                similar = Float(distance) <= similarityThreshold
            } else {
                similar = true // Can't compare — assume similar (time grouping already filtered)
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

    // MARK: - DCT-based perceptual hash (8x8)

    /// Compute a 64-bit perceptual hash for an image file.
    /// Algorithm: resize to 32x32 grayscale, apply DCT, take top-left 8x8, threshold by median.
    /// This matches the standard pHash used by imagehash (Python) that superpicky relies on.
    func computePHash(filePath: String) -> UInt64? {
        let url = URL(fileURLWithPath: filePath)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let cgImage = CGImageSourceCreateThumbnailAtIndex(source, 0, [
                  kCGImageSourceThumbnailMaxPixelSize: 64,
                  kCGImageSourceCreateThumbnailFromImageAlways: true,
              ] as CFDictionary) else {
            return nil
        }
        return Self.pHash(from: cgImage)
    }

    /// Compute the 64-bit DCT pHash from a CGImage.
    static func pHash(from cgImage: CGImage) -> UInt64? {
        // Step 1: Convert to 32x32 grayscale
        guard let grayscale = grayscale32x32(from: cgImage) else { return nil }

        // Step 2: Apply 2D DCT via Accelerate (row-wise then column-wise)
        let dctResult = dct2D(grayscale, size: 32)

        // Step 3: Extract top-left 8x8 (excluding DC component at [0,0])
        var lowFreq: [Float] = []
        for row in 0..<8 {
            for col in 0..<8 {
                if row == 0 && col == 0 { continue }
                lowFreq.append(dctResult[row * 32 + col])
            }
        }

        // Step 4: Compute median of the 63 low-frequency coefficients
        let sorted = lowFreq.sorted()
        let median: Float
        if sorted.count % 2 == 0 {
            median = (sorted[sorted.count / 2 - 1] + sorted[sorted.count / 2]) / 2
        } else {
            median = sorted[sorted.count / 2]
        }

        // Step 5: Build 64-bit hash: DC bit + 63 coefficient bits
        var hash: UInt64 = 0
        // Bit 63 (MSB): DC component > median
        if dctResult[0] > median {
            hash |= (1 << 63)
        }
        for (i, val) in lowFreq.enumerated() {
            if val > median {
                hash |= (1 << UInt64(62 - i))
            }
        }

        return hash
    }

    /// Convert a CGImage to 32x32 grayscale pixel values (row-major, 0.0–255.0).
    static func grayscale32x32(from image: CGImage) -> [Float]? {
        let size = 32
        var pixels = [UInt8](repeating: 0, count: size * size)
        guard let context = CGContext(
            data: &pixels,
            width: size,
            height: size,
            bitsPerComponent: 8,
            bytesPerRow: size,
            space: CGColorSpaceCreateDeviceGray(),
            bitmapInfo: CGImageAlphaInfo.none.rawValue
        ) else {return nil }
        context.interpolationQuality = .medium
        context.draw(image, in: CGRect(x: 0, y: 0, width: size, height: size))
        return pixels.map { Float($0) }
    }

    /// Cached DCT setup for size 32 (the standard pHash size).
    private nonisolated(unsafe) static let dctSetup32: vDSP_DFT_Setup? = vDSP_DCT_CreateSetup(nil, 32, .II)

    /// Apply a 2D DCT (type II) to a size x size matrix using Accelerate.
    static func dct2D(_ input: [Float], size: Int) -> [Float] {
        guard let setup = (size == 32) ? dctSetup32 : vDSP_DCT_CreateSetup(nil, vDSP_Length(size), .II) else {
            return input
        }

        // Row-wise DCT
        var rowResult = [Float](repeating: 0, count: size * size)
        for row in 0..<size {
            let offset = row * size
            var rowData = Array(input[offset..<offset + size])
            var rowOut = [Float](repeating: 0, count: size)
            vDSP_DCT_Execute(setup, &rowData, &rowOut)
            rowResult.replaceSubrange(offset..<offset + size, with: rowOut)
        }

        // Column-wise DCT (transpose, DCT rows, transpose back)
        var colResult = [Float](repeating: 0, count: size * size)
        for col in 0..<size {
            var colData = [Float](repeating: 0, count: size)
            for row in 0..<size {
                colData[row] = rowResult[row * size + col]
            }
            var colOut = [Float](repeating: 0, count: size)
            vDSP_DCT_Execute(setup, &colData, &colOut)
            for row in 0..<size {
                colResult[row * size + col] = colOut[row]
            }
        }

        return colResult
    }

    /// Hamming distance between two 64-bit hashes (number of differing bits).
    static func hammingDistance(_ a: UInt64, _ b: UInt64) -> Int {
        return (a ^ b).nonzeroBitCount
    }

    // MARK: - Vision feature print verification (legacy path)

    private func verifyWithFeaturePrint(_ group: BurstGroup) -> [BurstGroup] {
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
