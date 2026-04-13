import Foundation

struct SpeciesMatch: Codable, Identifiable, Sendable {
    var id: String { scientificName }
    let scientificName: String
    let commonName: String?
    let confidence: Float

    enum CodingKeys: String, CodingKey {
        case scientificName = "name"
        case commonName = "common_name"
        case confidence
    }
}
