import Foundation

struct SpeciesMatch: Codable, Identifiable, Sendable {
    var id: String { scientificName }
    let scientificName: String
    let commonName: String?
    let confidence: Float
    let cnName: String?
    let pinyin: String?
    let thresholdUsed: Float?

    enum CodingKeys: String, CodingKey {
        case scientificName = "name"
        case commonName = "common_name"
        case confidence
        case cnName = "cn_name"
        case pinyin
        case thresholdUsed = "threshold_used"
    }
}
