import Testing
import Foundation
@testable import SuperPicky

@Suite
struct SpeciesAssignmentEditorTests {

    private func match(_ ebird: String, common: String? = nil) -> SpeciesMatch {
        SpeciesMatch(
            scientificName: "Genus \(ebird)",
            commonName: common ?? ebird.capitalized,
            confidence: 0.9,
            cnName: nil,
            pinyin: nil,
            thresholdUsed: nil,
            ebirdCode: ebird
        )
    }

    // MARK: - add

    @Test
    func addAppendsWhenSpeciesIDIsNew() {
        let assigned = [match("baleag")]
        let updated = SpeciesAssignmentEditor.add(match("goleag"), to: assigned)
        #expect(updated?.map(\.speciesID) == ["baleag", "goleag"])
    }

    @Test
    func addReturnsNilWhenSpeciesIDAlreadyPresent() {
        let assigned = [match("baleag")]
        #expect(SpeciesAssignmentEditor.add(match("baleag"), to: assigned) == nil)
    }

    @Test
    func addDeduplicatesByEbirdCodeNotCommonName() {
        // Same ebirdCode with different commonName is still a dupe.
        let assigned = [match("baleag", common: "Bald Eagle")]
        let duplicate = match("baleag", common: "Renamed")
        #expect(SpeciesAssignmentEditor.add(duplicate, to: assigned) == nil)
    }

    @Test
    func addUsesScientificNameFallbackWhenEbirdCodeIsNil() {
        // speciesID falls back to scientificName when ebirdCode is nil.
        let custom = SpeciesMatch(
            scientificName: "Passer custom",
            commonName: "Custom Sparrow",
            confidence: 0, cnName: nil, pinyin: nil,
            thresholdUsed: nil, ebirdCode: nil
        )
        let again = SpeciesMatch(
            scientificName: "Passer custom",
            commonName: "Different label",
            confidence: 0, cnName: nil, pinyin: nil,
            thresholdUsed: nil, ebirdCode: nil
        )
        let first = SpeciesAssignmentEditor.add(custom, to: [])
        #expect(first?.count == 1)
        #expect(SpeciesAssignmentEditor.add(again, to: first ?? []) == nil)
    }

    // MARK: - remove

    @Test
    func removeDeletesAtIndex() {
        let assigned = [match("baleag"), match("goleag"), match("osprey")]
        let updated = SpeciesAssignmentEditor.remove(at: 1, from: assigned)
        #expect(updated.map(\.speciesID) == ["baleag", "osprey"])
    }

    @Test
    func removePrimaryPromotesNext() {
        // Not a named promotion — removing index 0 just leaves index 1 as the
        // new primary, which is the convention the view treats as "first".
        let assigned = [match("baleag"), match("goleag")]
        let updated = SpeciesAssignmentEditor.remove(at: 0, from: assigned)
        #expect(updated.map(\.speciesID) == ["goleag"])
    }

    // MARK: - makePrimary

    @Test
    func makePrimaryMovesEntryToSlotZero() {
        let assigned = [match("baleag"), match("goleag"), match("osprey")]
        let updated = SpeciesAssignmentEditor.makePrimary(at: 2, in: assigned)
        #expect(updated.map(\.speciesID) == ["osprey", "baleag", "goleag"])
    }

    @Test
    func makePrimaryOnZeroIsIdentity() {
        let assigned = [match("baleag"), match("goleag")]
        let updated = SpeciesAssignmentEditor.makePrimary(at: 0, in: assigned)
        #expect(updated.map(\.speciesID) == ["baleag", "goleag"])
    }

    // MARK: - unassignedCandidates

    @Test
    func unassignedCandidatesExcludesAlreadyAssignedIDs() {
        let all = [match("baleag"), match("goleag"), match("osprey")]
        let assigned = [match("baleag")]
        let filtered = SpeciesAssignmentEditor.unassignedCandidates(from: all, excluding: assigned)
        #expect(filtered.map(\.speciesID) == ["goleag", "osprey"])
    }

    @Test
    func unassignedCandidatesPreservesInputOrder() {
        let all = [match("osprey"), match("goleag"), match("baleag")]
        let assigned: [SpeciesMatch] = []
        let filtered = SpeciesAssignmentEditor.unassignedCandidates(from: all, excluding: assigned)
        #expect(filtered.map(\.speciesID) == ["osprey", "goleag", "baleag"])
    }

    @Test
    func unassignedCandidatesEmptyWhenAllAssigned() {
        let all = [match("baleag"), match("goleag")]
        let filtered = SpeciesAssignmentEditor.unassignedCandidates(from: all, excluding: all)
        #expect(filtered.isEmpty)
    }

    // MARK: - decodeCandidates

    @Test
    func decodeCandidatesReturnsEmptyForNil() {
        #expect(SpeciesAssignmentEditor.decodeCandidates(fromJSON: nil).isEmpty)
    }

    @Test
    func decodeCandidatesReturnsEmptyForMalformedJSON() {
        #expect(SpeciesAssignmentEditor.decodeCandidates(fromJSON: "{not json}").isEmpty)
        #expect(SpeciesAssignmentEditor.decodeCandidates(fromJSON: "").isEmpty)
    }

    @Test
    func decodeCandidatesRoundTripsValidList() {
        let list = [match("baleag"), match("goleag")]
        let data = try! JSONEncoder().encode(list)
        let json = String(data: data, encoding: .utf8)
        let decoded = SpeciesAssignmentEditor.decodeCandidates(fromJSON: json)
        #expect(decoded.map(\.speciesID) == ["baleag", "goleag"])
    }

    @Test
    func decodeCandidatesReturnsEmptyForWrongShape() {
        // Valid JSON but not a [SpeciesMatch] — e.g. a single object.
        #expect(SpeciesAssignmentEditor.decodeCandidates(fromJSON: "{\"name\":\"x\"}").isEmpty)
    }
}
