import Testing
import Foundation
@testable import SuperPicky

@Suite struct BatchSpeciesAggregatorTests {

    private func match(_ ebird: String, common: String? = nil, conf: Float = 0.9) -> SpeciesMatch {
        SpeciesMatch(
            scientificName: "Genus \(ebird)",
            commonName: common ?? ebird.capitalized,
            confidence: conf,
            cnName: nil, pinyin: nil,
            thresholdUsed: nil, ebirdCode: ebird
        )
    }

    private func photo(assigned: [SpeciesMatch], top5JSON: String? = nil) -> Photo {
        var p = Photo(filename: "p.CR3", filePath: "/tmp/p.CR3", folderPath: "/tmp")
        p.assignedSpecies = assigned
        p.speciesTop5JSON = top5JSON
        return p
    }

    // MARK: - unionAssigned

    @Test func unionAssignedReturnsEveryDistinctSpecies() {
        let a = match("eagle")
        let b = match("hawk")
        let c = match("owl")
        let photos = [
            photo(assigned: [a, b]),
            photo(assigned: [b, c]),
            photo(assigned: [a]),
        ]
        let result = BatchSpeciesAggregator.unionAssigned(photos)
        #expect(Set(result.map(\.species.speciesID)) == ["eagle", "hawk", "owl"])
    }

    @Test func unionAssignedCountsPhotosCarryingEach() {
        let a = match("eagle")
        let b = match("hawk")
        let photos = [
            photo(assigned: [a, b]),
            photo(assigned: [b]),
            photo(assigned: [b]),
        ]
        let result = BatchSpeciesAggregator.unionAssigned(photos)
        let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.species.speciesID, $0.photoCount) })
        #expect(byID["eagle"] == 1)
        #expect(byID["hawk"] == 3)
    }

    @Test func unionAssignedSortsByCountDescThenName() {
        let a = match("aaa", common: "AAA")
        let b = match("bbb", common: "BBB")
        let c = match("ccc", common: "CCC")
        let photos = [
            photo(assigned: [b]),
            photo(assigned: [b, c]),
            photo(assigned: [a, b]),
        ]
        let result = BatchSpeciesAggregator.unionAssigned(photos).map(\.species.speciesID)
        #expect(result == ["bbb", "aaa", "ccc"])
    }

    // MARK: - topCandidates

    @Test func topCandidatesUnionsTopKByMaxConfidence() throws {
        let a = match("eagle", conf: 0.4)
        let aHigh = match("eagle", conf: 0.8)
        let b = match("hawk", conf: 0.6)
        let c = match("owl", conf: 0.5)
        let json1 = try JSONEncoder().encode([a, b]).asString
        let json2 = try JSONEncoder().encode([aHigh, c]).asString
        let photos = [photo(assigned: [], top5JSON: json1),
                      photo(assigned: [], top5JSON: json2)]
        let result = BatchSpeciesAggregator.topCandidates(photos, limit: 10)
        let byID = Dictionary(uniqueKeysWithValues: result.map { ($0.speciesID, $0.confidence) })
        #expect(byID["eagle"] == 0.8)
        #expect(byID["hawk"] == 0.6)
        #expect(byID["owl"] == 0.5)
        #expect(result.first?.speciesID == "eagle")
    }

    @Test func topCandidatesCapsAtLimit() throws {
        let many = (0..<15).map { match("sp\($0)", conf: Float(15 - $0) / 15) }
        let json = try JSONEncoder().encode(many).asString
        let p = photo(assigned: [], top5JSON: json)
        let result = BatchSpeciesAggregator.topCandidates([p], limit: 10)
        #expect(result.count == 10)
        #expect(result.first?.speciesID == "sp0")
    }

    @Test func topCandidatesIgnoresNilAndMalformedJSON() {
        let p1 = photo(assigned: [], top5JSON: nil)
        let p2 = photo(assigned: [], top5JSON: "not valid json")
        let result = BatchSpeciesAggregator.topCandidates([p1, p2], limit: 10)
        #expect(result.isEmpty)
    }
}

private extension Data {
    var asString: String { String(data: self, encoding: .utf8) ?? "" }
}
