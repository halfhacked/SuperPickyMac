import Testing
import Foundation
@testable import SuperPicky

@Suite struct SpeciesKeywordTests {

    // MARK: - SpeciesMatch new fields

    @Test func speciesMatchDecodesNewFields() throws {
        let json = """
        {
            "name": "Alcedo atthis",
            "common_name": "Common Kingfisher",
            "confidence": 0.92,
            "cn_name": "普通翠鸟",
            "pinyin": "putongtsuiniao",
            "threshold_used": "gps"
        }
        """.data(using: .utf8)!

        let match = try JSONDecoder().decode(SpeciesMatch.self, from: json)
        #expect(match.scientificName == "Alcedo atthis")
        #expect(match.cnName == "普通翠鸟")
        #expect(match.pinyin == "putongtsuiniao")
        #expect(match.thresholdUsed == "gps")
    }

    @Test func speciesMatchDecodesWithoutNewFields() throws {
        let json = """
        {"name": "Alcedo atthis", "common_name": "Common Kingfisher", "confidence": 0.92}
        """.data(using: .utf8)!

        let match = try JSONDecoder().decode(SpeciesMatch.self, from: json)
        #expect(match.scientificName == "Alcedo atthis")
        #expect(match.cnName == nil)
        #expect(match.pinyin == nil)
        #expect(match.thresholdUsed == nil)
    }
}
