import Testing
import Foundation
@testable import SuperPicky

@Suite struct PickedFlagCalculatorTests {

    // MARK: - Helper to create a photo with specific scores

    private func makePhoto(
        starRating: Int = 5,
        aestheticsScore: Float? = nil,
        sharpnessScore: Float? = nil
    ) -> Photo {
        var photo = Photo(
            filename: "IMG_\(UUID().uuidString.prefix(8)).jpg",
            filePath: "/tmp/\(UUID().uuidString).jpg",
            folderPath: "/tmp"
        )
        photo.starRating = starRating
        photo.aestheticsScore = aestheticsScore
        photo.sharpnessScore = sharpnessScore
        return photo
    }

    // MARK: - Empty / no 5-star photos

    @Test func noPhotosReturnsEmpty() {
        let result = PickedFlagCalculator.calculatePickedIDs(photos: [], topPercentage: 25)
        #expect(result.isEmpty)
    }

    @Test func noFiveStarPhotosReturnsEmpty() {
        let photos = [
            makePhoto(starRating: 3, aestheticsScore: 7.0, sharpnessScore: 500),
            makePhoto(starRating: 4, aestheticsScore: 6.0, sharpnessScore: 400),
        ]
        let result = PickedFlagCalculator.calculatePickedIDs(photos: photos, topPercentage: 25)
        #expect(result.isEmpty)
    }

    // MARK: - Single 5-star photo

    @Test func singleFiveStarPhotoIsPicked() {
        let photo = makePhoto(starRating: 5, aestheticsScore: 6.0, sharpnessScore: 500)
        let result = PickedFlagCalculator.calculatePickedIDs(photos: [photo], topPercentage: 25)
        #expect(result.count == 1)
        #expect(result.contains(photo.id))
    }

    // MARK: - top_count minimum is 1

    @Test func topCountMinimumIsOne() {
        // With 2 five-star photos and 25%, raw top_count = 0.5 → floor to 0 → clamped to 1
        let p1 = makePhoto(starRating: 5, aestheticsScore: 7.0, sharpnessScore: 600)
        let p2 = makePhoto(starRating: 5, aestheticsScore: 5.0, sharpnessScore: 300)
        let result = PickedFlagCalculator.calculatePickedIDs(photos: [p1, p2], topPercentage: 25)
        // top_count=1, so only the top-1 by aesthetics (p1) and top-1 by sharpness (p1)
        // intersection = {p1}
        #expect(result.count == 1)
        #expect(result.contains(p1.id))
    }

    // MARK: - Intersection logic

    @Test func intersectionOfTopAestheticsAndSharpness() {
        // 4 five-star photos, 50% → top_count = 2
        // By aesthetics desc: p1(8.0), p2(7.0), p3(6.0), p4(5.0) → top 2 = {p1, p2}
        // By sharpness desc: p3(900), p1(800), p4(700), p2(600) → top 2 = {p3, p1}
        // Intersection = {p1}
        let p1 = makePhoto(starRating: 5, aestheticsScore: 8.0, sharpnessScore: 800)
        let p2 = makePhoto(starRating: 5, aestheticsScore: 7.0, sharpnessScore: 600)
        let p3 = makePhoto(starRating: 5, aestheticsScore: 6.0, sharpnessScore: 900)
        let p4 = makePhoto(starRating: 5, aestheticsScore: 5.0, sharpnessScore: 700)

        let result = PickedFlagCalculator.calculatePickedIDs(
            photos: [p1, p2, p3, p4], topPercentage: 50
        )
        #expect(result.count == 1)
        #expect(result.contains(p1.id))
    }

    @Test func emptyIntersectionWhenTopSetsDisjoint() {
        // 4 five-star photos, 25% → top_count = 1
        // Top aesthetics = {p1}, top sharpness = {p2}
        // Intersection = empty
        let p1 = makePhoto(starRating: 5, aestheticsScore: 9.0, sharpnessScore: 100)
        let p2 = makePhoto(starRating: 5, aestheticsScore: 3.5, sharpnessScore: 999)
        let p3 = makePhoto(starRating: 5, aestheticsScore: 5.0, sharpnessScore: 500)
        let p4 = makePhoto(starRating: 5, aestheticsScore: 4.0, sharpnessScore: 400)

        let result = PickedFlagCalculator.calculatePickedIDs(
            photos: [p1, p2, p3, p4], topPercentage: 25
        )
        #expect(result.isEmpty)
    }

    // MARK: - Percentage boundary

    @Test func hundredPercentPicksAll() {
        // 100% → top_count = count → all 5-star photos in both sets → intersection = all
        let p1 = makePhoto(starRating: 5, aestheticsScore: 8.0, sharpnessScore: 800)
        let p2 = makePhoto(starRating: 5, aestheticsScore: 7.0, sharpnessScore: 700)
        let p3 = makePhoto(starRating: 5, aestheticsScore: 6.0, sharpnessScore: 600)

        let result = PickedFlagCalculator.calculatePickedIDs(
            photos: [p1, p2, p3], topPercentage: 100
        )
        #expect(result.count == 3)
    }

    // MARK: - Filters only 5-star photos

    @Test func ignoresNonFiveStarPhotos() {
        let fiveStar = makePhoto(starRating: 5, aestheticsScore: 7.0, sharpnessScore: 700)
        let fourStar = makePhoto(starRating: 4, aestheticsScore: 9.0, sharpnessScore: 900)

        let result = PickedFlagCalculator.calculatePickedIDs(
            photos: [fiveStar, fourStar], topPercentage: 100
        )
        #expect(result.count == 1)
        #expect(result.contains(fiveStar.id))
        #expect(!result.contains(fourStar.id))
    }

    // MARK: - Nil scores treated as 0

    @Test func nilScoresTreatedAsZero() {
        // Photo with nil aesthetics should be ranked lowest
        let withScores = makePhoto(starRating: 5, aestheticsScore: 7.0, sharpnessScore: 700)
        let nilAesthetics = makePhoto(starRating: 5, aestheticsScore: nil, sharpnessScore: 800)
        let nilSharpness = makePhoto(starRating: 5, aestheticsScore: 8.0, sharpnessScore: nil)

        // 3 photos, 33% → top_count = 1
        let result = PickedFlagCalculator.calculatePickedIDs(
            photos: [withScores, nilAesthetics, nilSharpness], topPercentage: 33
        )
        // top aesthetics: nilSharpness(8.0) > withScores(7.0) > nilAesthetics(0) → {nilSharpness}
        // top sharpness: nilAesthetics(800) > withScores(700) > nilSharpness(0) → {nilAesthetics}
        // intersection = empty
        #expect(result.isEmpty)
    }

    // MARK: - Multiple picked photos

    @Test func multiplePhotosInIntersection() {
        // 8 five-star photos, 50% → top_count = 4
        // Design: p1, p2, p3, p4 are top in BOTH aesthetics and sharpness
        let p1 = makePhoto(starRating: 5, aestheticsScore: 9.0, sharpnessScore: 900)
        let p2 = makePhoto(starRating: 5, aestheticsScore: 8.5, sharpnessScore: 850)
        let p3 = makePhoto(starRating: 5, aestheticsScore: 8.0, sharpnessScore: 800)
        let p4 = makePhoto(starRating: 5, aestheticsScore: 7.5, sharpnessScore: 750)
        let p5 = makePhoto(starRating: 5, aestheticsScore: 5.0, sharpnessScore: 500)
        let p6 = makePhoto(starRating: 5, aestheticsScore: 4.5, sharpnessScore: 450)
        let p7 = makePhoto(starRating: 5, aestheticsScore: 4.0, sharpnessScore: 400)
        let p8 = makePhoto(starRating: 5, aestheticsScore: 3.5, sharpnessScore: 350)

        let result = PickedFlagCalculator.calculatePickedIDs(
            photos: [p1, p2, p3, p4, p5, p6, p7, p8], topPercentage: 50
        )
        #expect(result.count == 4)
        #expect(result.contains(p1.id))
        #expect(result.contains(p2.id))
        #expect(result.contains(p3.id))
        #expect(result.contains(p4.id))
    }

    // MARK: - Integration: pipeline calculates picked flags

    @Test func pipelineCalculatesPickedFlags() async throws {
        let tempDir = try makeTempDir()

        // Create 4 JPEG files
        for i in 0..<4 {
            let url = tempDir.appendingPathComponent("IMG_\(i).jpg")
            createTestJPEG(at: url)
        }

        // Mock client that returns a bird with varying aesthetics
        var mockClient = MockInferenceClient()
        mockClient.identifyBirds = [
            BirdDetection(
                bbox: CGRect(x: 0.1, y: 0.1, width: 0.5, height: 0.5),
                confidence: 0.95,
                mask: Data()
            )
        ]
        // High aesthetics → all photos should get 5 stars with these thresholds
        mockClient.aestheticsResult = AestheticsResponse(score: 6.0, distribution: [])

        let config = RatingEngine.Config(sharpnessThreshold: 0, aestheticsThreshold: 0)
        let pipeline = PipelineCoordinator(inferenceClient: mockClient)

        await pipeline.process(
            folder: tempDir,
            ratingConfig: config,
            exposureEnabled: false,
            exposureThreshold: 0.10,
            burstDetectionEnabled: false
        )

        // After processing, run picked flag calculation
        let db = try ReportDatabase(folderPath: tempDir)
        let photos = try db.fetchAllPhotos()

        // All should be 5-star with these thresholds
        let fiveStars = photos.filter { $0.starRating == 5 }
        #expect(fiveStars.count == 4)

        // Calculate and apply picked flags
        let pickedIDs = PickedFlagCalculator.calculatePickedIDs(
            photos: photos, topPercentage: 25
        )

        // 4 five-star photos, 25% → top_count=1
        // Since all have same aesthetics/sharpness, at least some should be picked
        // (all have same score, so top-1 of each = first in sort order, intersection = 1)
        #expect(pickedIDs.count >= 1)
    }
}
