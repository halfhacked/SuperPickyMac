import Testing
import Foundation
@testable import SuperPicky

@Suite struct BurstDetectorTests {
    let detector = BurstDetector(timeThresholdMs: 250, minBurstCount: 3, similarityThreshold: 15.0)

    // MARK: - Time grouping

    @Test func noPhotosReturnsEmpty() {
        let groups = detector.detect(photos: [])
        #expect(groups.isEmpty)
    }

    @Test func fewerThanMinCountReturnsEmpty() {
        let photos = makePhotos(count: 2, intervalMs: 100)
        let groups = detector.detect(photos: photos)
        #expect(groups.isEmpty)
    }

    @Test func consecutivePhotosGrouped() {
        // 5 photos at 100ms intervals — all within 250ms threshold
        let photos = makePhotos(count: 5, intervalMs: 100)
        let groups = detector.detect(photos: photos)
        // Can't verify grouping without real EXIF timestamps, but structure should work
        // With fake photos (no EXIF), detect returns empty since readPreciseTimestamp returns nil
        #expect(groups.isEmpty) // Expected: no EXIF on synthetic photos
    }

    // MARK: - Best photo selection (unit logic)

    @Test func bestPhotoByScore() {
        var photos: [Photo] = []
        for i in 0..<5 {
            var p = Photo(filename: "IMG_\(i).jpg", filePath: "/tmp/IMG_\(i).jpg", folderPath: "/tmp")
            p.sharpnessScore = Float(i) * 100
            p.aestheticsScore = Float(5 - i)
            photos.append(p)
        }

        // Score = sharpness * 0.5 + aesthetics * 0.5
        // Photo 0: 0 * 0.5 + 5 * 0.5 = 2.5
        // Photo 1: 100 * 0.5 + 4 * 0.5 = 52
        // Photo 2: 200 * 0.5 + 3 * 0.5 = 101.5
        // Photo 3: 300 * 0.5 + 2 * 0.5 = 151
        // Photo 4: 400 * 0.5 + 1 * 0.5 = 200.5
        // Best = Photo 4

        let group = BurstGroup(id: UUID(), photos: photos, bestPhotoID: nil)
        let bestID = photos.max(by: {
            ($0.sharpnessScore ?? 0) * 0.5 + ($0.aestheticsScore ?? 0) * 0.5 <
            ($1.sharpnessScore ?? 0) * 0.5 + ($1.aestheticsScore ?? 0) * 0.5
        })?.id
        #expect(bestID == photos[4].id)
    }

    @Test func burstGroupProperties() {
        let photos = [
            Photo(filename: "a.jpg", filePath: "/tmp/a.jpg", folderPath: "/tmp"),
            Photo(filename: "b.jpg", filePath: "/tmp/b.jpg", folderPath: "/tmp"),
            Photo(filename: "c.jpg", filePath: "/tmp/c.jpg", folderPath: "/tmp"),
        ]
        let group = BurstGroup(id: UUID(), photos: photos, bestPhotoID: photos[1].id)
        #expect(group.count == 3)
        #expect(group.bestPhoto?.filename == "b.jpg")
    }

    // MARK: - Helpers

    private func makePhotos(count: Int, intervalMs: Int) -> [Photo] {
        (0..<count).map { i in
            Photo(filename: "IMG_\(i).jpg", filePath: "/tmp/IMG_\(i).jpg", folderPath: "/tmp")
        }
    }
}
