import Testing
import Foundation
@testable import SuperPicky

@Suite struct StarFilterTests {

    // MARK: - Helper

    private func makePhotos(ratings: [Int]) -> [Photo] {
        ratings.map { rating in
            var photo = Photo(
                filename: "IMG_\(UUID().uuidString).CR3",
                filePath: "/path/to/IMG.CR3",
                folderPath: "/path/to"
            )
            photo.starRating = rating
            return photo
        }
    }

    // MARK: - Filter logic

    @Test func filterZeroShowsAll() {
        let photos = makePhotos(ratings: [0, 1, 2, 3, 4, 5])
        let filtered = photos.filter { $0.starRating >= 0 }
        #expect(filtered.count == 6)
    }

    @Test func filterThreeShowsThreeAndAbove() {
        let photos = makePhotos(ratings: [0, 1, 2, 3, 4, 5])
        let filtered = photos.filter { $0.starRating >= 3 }
        #expect(filtered.count == 3)
        #expect(filtered.allSatisfy { $0.starRating >= 3 })
    }

    @Test func filterFiveShowsOnlyFive() {
        let photos = makePhotos(ratings: [0, 1, 2, 3, 4, 5, 5])
        let filtered = photos.filter { $0.starRating >= 5 }
        #expect(filtered.count == 2)
    }

    @Test func filterAboveMaxShowsNone() {
        let photos = makePhotos(ratings: [0, 1, 2, 3, 4])
        let filtered = photos.filter { $0.starRating >= 5 }
        #expect(filtered.count == 0)
    }

    @Test func filterOnEmptyArray() {
        let photos: [Photo] = []
        let filtered = photos.filter { $0.starRating >= 3 }
        #expect(filtered.count == 0)
    }
}
