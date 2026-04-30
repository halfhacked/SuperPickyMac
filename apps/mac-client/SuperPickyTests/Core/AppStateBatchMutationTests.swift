import Testing
import Foundation
@testable import SuperPicky

@Suite(.serialized) struct AppStateBatchMutationTests {

    private func makeTempFolder() throws -> URL {
        let folder = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder
    }

    private func match(_ ebird: String, conf: Float = 0.9) -> SpeciesMatch {
        SpeciesMatch(
            scientificName: "Genus \(ebird)",
            commonName: ebird.capitalized,
            confidence: conf,
            cnName: nil, pinyin: nil,
            thresholdUsed: nil, ebirdCode: ebird
        )
    }

    private func seedPhotos(_ count: Int, into folder: URL) throws -> [UUID] {
        let db = try ReportDatabase(folderPath: folder)
        var ids: [UUID] = []
        for i in 0..<count {
            var p = Photo(
                filename: "p\(i).CR3",
                filePath: folder.appendingPathComponent("p\(i).CR3").path,
                folderPath: folder.path
            )
            try db.save(&p)
            ids.append(p.id)
        }
        return ids
    }

    // MARK: - setPick(ids:)

    @Test func setPickPicksAllWhenAnyUnpicked() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        app.setPick(ids: [ids[0]])
        let mixed = Set(ids[0...2])
        app.setPick(ids: mixed)

        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            #expect(try db.fetchPhoto(id: id)?.isPick == true)
        }
    }

    @Test func setPickUnpicksAllWhenAllPicked() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        let s = Set(ids)
        app.setPick(ids: s)
        app.setPick(ids: s)

        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            #expect(try db.fetchPhoto(id: id)?.isPick == false)
        }
    }

    @Test func setPickSinglePhotoMatchesLegacyToggleSemantics() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(1, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        app.setPick(ids: [ids[0]])
        #expect(app.allPhotosForTesting().first?.isPick == true)
        app.setPick(ids: [ids[0]])
        #expect(app.allPhotosForTesting().first?.isPick == false)
    }

    @Test func setPickPushesOneUndoEntry() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        app.setPick(ids: Set(ids))
        let stackSizeAfter = app.undoStackSizeForTesting()
        #expect(stackSizeAfter == 1)

        app.undoLastAction()
        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            #expect(try db.fetchPhoto(id: id)?.isPick == false)
        }
    }

    // MARK: - setRating(ids:rating:)

    @Test func setRatingAppliesToEveryID() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)

        app.setRating(ids: Set(ids), rating: 4)

        let db = try ReportDatabase(folderPath: folder)
        for id in ids {
            #expect(try db.fetchPhoto(id: id)?.starRating == 4)
        }
    }

    // MARK: - reject(ids:)

    @Test func rejectMakesPhotosLeaveFilteredArray() throws {
        let folder = try makeTempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let ids = try seedPhotos(3, into: folder)
        let app = AppState()
        app.loadPhotos(for: folder)
        app.sidebarSelection = .rating(3)

        app.setRating(ids: Set(ids), rating: 3)
        app.applyFilter()
        #expect(app.photos.count == 3)

        app.reject(ids: [ids[0]])
        #expect(app.photos.count == 2)
        #expect(!app.photos.contains(where: { $0.id == ids[0] }))
    }
}
