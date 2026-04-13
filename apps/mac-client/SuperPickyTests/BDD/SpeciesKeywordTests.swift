import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import SuperPicky

@Suite struct SpeciesKeywordTests {

    // MARK: - Keyword formatting

    @Test func formatKeywordsDefaultTemplate() {
        let kw = KeywordWriter.formatKeywords(
            template: "{cn} {en} {pinyin}",
            en: "Common Kingfisher", cn: "普通翠鸟", latin: "Alcedo atthis", pinyin: "putongtsuiniao"
        )
        #expect(kw == ["普通翠鸟", "Common Kingfisher", "putongtsuiniao"])
    }

    @Test func formatKeywordsLatinOnly() {
        let kw = KeywordWriter.formatKeywords(
            template: "{latin}",
            en: "Common Kingfisher", cn: "普通翠鸟", latin: "Alcedo atthis", pinyin: "putongtsuiniao"
        )
        #expect(kw == ["Alcedo atthis"])
    }

    @Test func formatKeywordsAllTokens() {
        let kw = KeywordWriter.formatKeywords(
            template: "{en} {cn} {latin} {pinyin}",
            en: "Eagle", cn: "鹰", latin: "Aquila", pinyin: "ying"
        )
        #expect(kw == ["Eagle", "鹰", "Aquila", "ying"])
    }

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
