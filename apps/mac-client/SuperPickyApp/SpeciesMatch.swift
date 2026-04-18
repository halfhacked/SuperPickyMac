import Foundation

struct SpeciesMatch: Codable, Identifiable, Sendable, Hashable {
    var id: String { speciesID }
    let scientificName: String
    let commonName: String?
    let confidence: Float
    let cnName: String?
    let pinyin: String?
    let thresholdUsed: String?
    /// Stable eBird species code (e.g. "mallar3") when the match came from
    /// the OSEA class vocabulary. `nil` for user-entered custom species the
    /// model doesn't know. Used as the bucket key for the sidebar and filter
    /// so renaming the common name doesn't jump the photo between buckets.
    let ebirdCode: String?

    /// Stable identifier: eBird code when available, otherwise fall back to
    /// the scientific name. Never the localized common name.
    var speciesID: String { ebirdCode ?? scientificName }

    init(scientificName: String,
         commonName: String?,
         confidence: Float,
         cnName: String?,
         pinyin: String?,
         thresholdUsed: String?,
         ebirdCode: String? = nil) {
        self.scientificName = scientificName
        self.commonName = commonName
        self.confidence = confidence
        self.cnName = cnName
        self.pinyin = pinyin
        self.thresholdUsed = thresholdUsed
        self.ebirdCode = ebirdCode
    }

    enum CodingKeys: String, CodingKey {
        case scientificName = "name"
        case commonName = "common_name"
        case confidence
        case cnName = "cn_name"
        case pinyin
        case thresholdUsed = "threshold_used"
        case ebirdCode = "ebird_code"
    }
}
