import Testing
import Foundation
@testable import SuperPicky

@Suite struct PhotoSelectionTests {

    private func makePhotos(_ count: Int, folder: URL = URL(fileURLWithPath: "/tmp/sel")) -> [Photo] {
        (0..<count).map { i in
            Photo(filename: "p\(i).CR3",
                  filePath: folder.appendingPathComponent("p\(i).CR3").path,
                  folderPath: folder.path)
        }
    }

    // MARK: - click

    @Test func clickSetsActiveAndAnchorAndCollapsesSelection() {
        let photos = makePhotos(3)
        let s = PhotoSelection()
        s.click(photos[1].id, photos: photos)
        #expect(s.selectedIDs == [photos[1].id])
        #expect(s.activeID == photos[1].id)
        #expect(s.anchorID == photos[1].id)
        s.click(photos[2].id, photos: photos)
        #expect(s.selectedIDs == [photos[2].id])
        #expect(s.activeID == photos[2].id)
        #expect(s.anchorID == photos[2].id)
    }

    // MARK: - shiftClick

    @Test func shiftClickWithoutAnchorBehavesLikePlainClick() {
        let photos = makePhotos(3)
        let s = PhotoSelection()
        s.shiftClick(photos[2].id, photos: photos)
        #expect(s.selectedIDs == [photos[2].id])
        #expect(s.activeID == photos[2].id)
    }

    @Test func shiftClickExtendsRangeFromAnchor() {
        let photos = makePhotos(5)
        let s = PhotoSelection()
        s.click(photos[1].id, photos: photos)
        s.shiftClick(photos[3].id, photos: photos)
        #expect(s.selectedIDs == Set(photos[1...3].map(\.id)))
        #expect(s.activeID == photos[3].id)
        #expect(s.anchorID == photos[1].id) // unchanged
    }

    @Test func shiftClickReplacesPriorRangeFromSameAnchor() {
        let photos = makePhotos(5)
        let s = PhotoSelection()
        s.click(photos[2].id, photos: photos)
        s.shiftClick(photos[4].id, photos: photos) // {2,3,4}
        s.shiftClick(photos[0].id, photos: photos) // {0,1,2}
        #expect(s.selectedIDs == Set(photos[0...2].map(\.id)))
        #expect(s.activeID == photos[0].id)
    }

    // MARK: - cmdClick

    @Test func cmdClickAddsAndUpdatesAnchorAndActive() {
        let photos = makePhotos(3)
        let s = PhotoSelection()
        s.click(photos[0].id, photos: photos)
        s.cmdClick(photos[2].id, photos: photos)
        #expect(s.selectedIDs == [photos[0].id, photos[2].id])
        #expect(s.activeID == photos[2].id)
        #expect(s.anchorID == photos[2].id)
    }

    @Test func cmdClickRemovesPresent() {
        let photos = makePhotos(3)
        let s = PhotoSelection()
        s.click(photos[0].id, photos: photos)
        s.cmdClick(photos[2].id, photos: photos)
        s.cmdClick(photos[2].id, photos: photos)
        #expect(s.selectedIDs == [photos[0].id])
    }

    @Test func cmdClickRemovingActiveFallsBackToFirstRemaining() {
        let photos = makePhotos(3)
        let s = PhotoSelection()
        s.click(photos[0].id, photos: photos)
        s.cmdClick(photos[2].id, photos: photos) // active = p2
        s.cmdClick(photos[2].id, photos: photos) // remove p2
        #expect(s.activeID == photos[0].id)
        #expect(s.selectedIDs == [photos[0].id])
    }

    @Test func cmdClickEmptyingSelectionLeavesNilActive() {
        let photos = makePhotos(2)
        let s = PhotoSelection()
        s.click(photos[0].id, photos: photos)
        s.cmdClick(photos[0].id, photos: photos)
        #expect(s.selectedIDs.isEmpty)
        #expect(s.activeID == nil)
    }

    // MARK: - arrow

    @Test func arrowCollapsesAndMoves() {
        let photos = makePhotos(4)
        let s = PhotoSelection()
        s.click(photos[1].id, photos: photos)
        s.shiftClick(photos[3].id, photos: photos) // {1,2,3}, active=3
        s.arrow(direction: -1, photos: photos)
        // collapse to active (3), then move -1 → photos[2]
        #expect(s.selectedIDs == [photos[2].id])
        #expect(s.activeID == photos[2].id)
    }

    @Test func arrowAtEndClampsToActive() {
        let photos = makePhotos(4)
        let s = PhotoSelection()
        s.click(photos[3].id, photos: photos)
        s.arrow(direction: 1, photos: photos)
        #expect(s.activeID == photos[3].id)
        #expect(s.selectedIDs == [photos[3].id])
    }

    // MARK: - shiftArrow

    @Test func shiftArrowExtendsByOne() {
        let photos = makePhotos(5)
        let s = PhotoSelection()
        s.click(photos[1].id, photos: photos)
        s.shiftArrow(direction: 1, photos: photos)
        #expect(s.selectedIDs == [photos[1].id, photos[2].id])
        #expect(s.activeID == photos[2].id)
        #expect(s.anchorID == photos[1].id)
    }

    @Test func shiftArrowAtEndIsNoOp() {
        let photos = makePhotos(2)
        let s = PhotoSelection()
        s.click(photos[1].id, photos: photos)
        s.shiftArrow(direction: 1, photos: photos)
        #expect(s.selectedIDs == [photos[1].id])
        #expect(s.activeID == photos[1].id)
    }

    // MARK: - selectAll / collapseToActive / clear

    @Test func selectAllPicksEveryPhoto() {
        let photos = makePhotos(3)
        let s = PhotoSelection()
        s.click(photos[1].id, photos: photos)
        s.selectAll(photos: photos)
        #expect(s.selectedIDs == Set(photos.map(\.id)))
        #expect(s.activeID == photos[1].id) // active preserved
    }

    @Test func collapseToActiveDropsOthers() {
        let photos = makePhotos(3)
        let s = PhotoSelection()
        s.click(photos[0].id, photos: photos)
        s.shiftClick(photos[2].id, photos: photos)
        s.collapseToActive()
        #expect(s.selectedIDs == [photos[2].id])
        #expect(s.activeID == photos[2].id)
    }

    @Test func clearEmptiesEverything() {
        let photos = makePhotos(2)
        let s = PhotoSelection()
        s.click(photos[0].id, photos: photos)
        s.clear()
        #expect(s.selectedIDs.isEmpty)
        #expect(s.activeID == nil)
        #expect(s.anchorID == nil)
    }

    // MARK: - reconcile

    @Test func reconcileDropsMissingAndKeepsActiveIfPresent() {
        let photos = makePhotos(4)
        let s = PhotoSelection()
        s.click(photos[1].id, photos: photos)
        s.shiftClick(photos[3].id, photos: photos) // {1,2,3}, active=3
        s.reconcile(with: [photos[0], photos[2], photos[3]])
        #expect(s.selectedIDs == [photos[2].id, photos[3].id])
        #expect(s.activeID == photos[3].id)
    }

    @Test func reconcileFallsBackWhenActiveDropped() {
        let photos = makePhotos(4)
        let s = PhotoSelection()
        s.click(photos[1].id, photos: photos)
        s.shiftClick(photos[3].id, photos: photos) // {1,2,3}, active=3
        s.reconcile(with: [photos[0], photos[1], photos[2]])
        #expect(s.selectedIDs == [photos[1].id, photos[2].id])
        #expect(s.activeID == photos[1].id)
    }

    @Test func reconcileEmptyClearsAll() {
        let photos = makePhotos(3)
        let s = PhotoSelection()
        s.click(photos[1].id, photos: photos)
        s.reconcile(with: [])
        #expect(s.selectedIDs.isEmpty)
        #expect(s.activeID == nil)
    }
}
