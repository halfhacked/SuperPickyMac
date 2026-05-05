import Testing
import Foundation
@testable import SuperPicky

@Suite struct PhotoSelectionEditorTests {

    private func ids(_ count: Int) -> [UUID] {
        (0..<count).map { _ in UUID() }
    }

    private func photos(from ids: [UUID]) -> [Photo] {
        ids.enumerated().map { i, id in
            var p = Photo(filename: "p\(i).CR3",
                          filePath: "/tmp/p\(i).CR3",
                          folderPath: "/tmp")
            p.id = id
            return p
        }
    }

    // MARK: - rangeIDs

    @Test func rangeIDsForwardIncludesEndpoints() {
        let xs = ids(5)
        let r = PhotoSelectionEditor.rangeIDs(from: xs[1], to: xs[3], in: photos(from: xs))
        #expect(r == [xs[1], xs[2], xs[3]])
    }

    @Test func rangeIDsBackwardSwapsEndpoints() {
        let xs = ids(5)
        let r = PhotoSelectionEditor.rangeIDs(from: xs[3], to: xs[1], in: photos(from: xs))
        #expect(r == [xs[1], xs[2], xs[3]])
    }

    @Test func rangeIDsSameAnchorReturnsSingle() {
        let xs = ids(3)
        let r = PhotoSelectionEditor.rangeIDs(from: xs[1], to: xs[1], in: photos(from: xs))
        #expect(r == [xs[1]])
    }

    @Test func rangeIDsMissingAnchorReturnsEmpty() {
        let xs = ids(3)
        let foreign = UUID()
        let r = PhotoSelectionEditor.rangeIDs(from: foreign, to: xs[1], in: photos(from: xs))
        #expect(r.isEmpty)
    }

    // MARK: - toggling

    @Test func toggleAddsWhenAbsent() {
        let xs = ids(3)
        var set: Set<UUID> = [xs[0]]
        PhotoSelectionEditor.toggle(xs[1], in: &set)
        #expect(set == [xs[0], xs[1]])
    }

    @Test func toggleRemovesWhenPresent() {
        let xs = ids(3)
        var set: Set<UUID> = [xs[0], xs[1]]
        PhotoSelectionEditor.toggle(xs[1], in: &set)
        #expect(set == [xs[0]])
    }

    // MARK: - reconcile

    @Test func reconcileKeepsSurvivingIDs() {
        let xs = ids(4)
        var set: Set<UUID> = [xs[0], xs[1], xs[3]]
        PhotoSelectionEditor.reconcile(set: &set, against: photos(from: [xs[0], xs[2], xs[3]]))
        #expect(set == [xs[0], xs[3]])
    }

    @Test func reconcileEmptiesIfNoOverlap() {
        let xs = ids(3)
        var set: Set<UUID> = [xs[0], xs[1]]
        PhotoSelectionEditor.reconcile(set: &set, against: photos(from: ids(2)))
        #expect(set.isEmpty)
    }

    // MARK: - neighbor

    @Test func neighborForwardWrapsToFirstWhenIndexInvalid() {
        let xs = ids(3)
        let n = PhotoSelectionEditor.neighbor(of: nil, direction: 1, in: photos(from: xs))
        #expect(n == xs.first)
    }

    @Test func neighborForwardClampsAtEnd() {
        let xs = ids(3)
        let n = PhotoSelectionEditor.neighbor(of: xs[2], direction: 1, in: photos(from: xs))
        #expect(n == xs[2])
    }

    @Test func neighborBackwardClampsAtStart() {
        let xs = ids(3)
        let n = PhotoSelectionEditor.neighbor(of: xs[0], direction: -1, in: photos(from: xs))
        #expect(n == xs[0])
    }
}
