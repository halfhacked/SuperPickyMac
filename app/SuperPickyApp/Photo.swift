import Foundation
import GRDB

struct Photo: Identifiable, Codable, Sendable, FetchableRecord, PersistableRecord {
    var id: UUID
    var filename: String
    var filePath: String
    var folderPath: String
    var dateCreated: Date
    var birdConfidence: Float?
    var aestheticsScore: Float?
    var leftEyeX: Float?
    var leftEyeY: Float?
    var leftEyeVis: Float?
    var rightEyeX: Float?
    var rightEyeY: Float?
    var rightEyeVis: Float?
    var beakX: Float?
    var beakY: Float?
    var beakVis: Float?
    var isFlying: Bool
    var flightConfidence: Float?
    var sharpnessScore: Float?
    var exposureStatus: String?
    var starRating: Int
    var isRejected: Bool
    var isPick: Bool
    var speciesScientificName: String?
    var speciesCommonName: String?
    var speciesCnName: String?
    var speciesPinyin: String?
    var speciesConfidence: Float?
    var burstGroupID: UUID?
    var isBurstBest: Bool
    var isManualRating: Bool

    // Parity-harness fields: persisted by PipelineCoordinator but not shown
    // in the UI. All JSON-encoded strings so we don't need typed columns
    // for variable-length payloads (top-5 list, 10-bin distribution, bbox).
    var speciesTop5JSON: String?
    var aestheticsDistributionJSON: String?
    var birdBboxJSON: String?

    /// JSON-encoded `[SpeciesMatch]` — the set of species currently tagged on
    /// this photo. First entry is the "primary" species (mirrored into the
    /// scalar `species*` columns for back-compat with burst-dominance,
    /// sidebar hierarchy, and legacy queries). Empty/nil when the photo is
    /// unidentified. Written only via the `assignedSpecies` accessor so the
    /// primary-column mirror stays in sync.
    var assignedSpeciesJSON: String?

    // Reverse-geocoded location from the photo's GPS EXIF (resolved via
    // CLGeocoder + cell-keyed cache in ReverseGeocoder). Written to the
    // XMP sidecar as photoshop:City / State / Country / Iptc4xmpCore:
    // CountryCode / Location so Lightroom, Bridge, and Photos pick them up.
    var locationCity: String?
    var locationState: String?
    var locationCountry: String?
    var locationCountryCode: String?
    var locationSublocation: String?

    static let databaseTableName = "photos"

    init(id: UUID = UUID(), filename: String, filePath: String, folderPath: String, dateCreated: Date = Date()) {
        self.id = id
        self.filename = filename
        self.filePath = filePath
        self.folderPath = folderPath
        self.dateCreated = dateCreated
        self.isFlying = false
        self.starRating = 0
        self.isRejected = false
        self.isPick = false
        self.isBurstBest = false
        self.isManualRating = false
    }

    mutating func applyLocation(_ loc: LocationInfo) {
        locationCity = loc.city
        locationState = loc.state
        locationCountry = loc.country
        locationCountryCode = loc.countryCode
        locationSublocation = loc.sublocation
    }

    /// Copy species fields from another burst member. Bursts are rapid-
    /// fire frames of the same subject, so once one frame is confidently
    /// identified we propagate that label to every other member whose own
    /// OSEA run fell below the threshold (or swung to an implausible
    /// lookalike due to a slightly-different crop).
    mutating func inheritSpecies(from donor: Photo) {
        speciesCommonName = donor.speciesCommonName
        speciesScientificName = donor.speciesScientificName
        speciesCnName = donor.speciesCnName
        speciesPinyin = donor.speciesPinyin
        speciesConfidence = donor.speciesConfidence
        assignedSpeciesJSON = donor.assignedSpeciesJSON
    }

    var hasSpecies: Bool {
        speciesCommonName != nil || speciesScientificName != nil
    }

    /// Currently-assigned species list, decoded from `assignedSpeciesJSON`.
    /// Writing this property updates the JSON blob *and* mirrors the first
    /// entry into the scalar `species*` columns so sidebar hierarchy,
    /// burst-dominance, and legacy queries keep working without change.
    var assignedSpecies: [SpeciesMatch] {
        get {
            if let json = assignedSpeciesJSON,
               let data = json.data(using: .utf8),
               let list = try? JSONDecoder().decode([SpeciesMatch].self, from: data) {
                return list
            }
            // Fall back to the scalar primary columns so rows written
            // before migration v8, or synthesized by tests that only set
            // scalar fields, still report a sensible list. Scientific name
            // may be missing (common-only, cn-only cases): derive a stable
            // scientific-name slot from the common or Chinese name so
            // `SpeciesMatch.speciesID` stays non-empty.
            if speciesCommonName != nil || speciesScientificName != nil
                || speciesCnName != nil || speciesPinyin != nil {
                let sci = speciesScientificName
                    ?? speciesCommonName
                    ?? speciesCnName
                    ?? speciesPinyin
                    ?? ""
                return [SpeciesMatch(
                    scientificName: sci,
                    commonName: speciesCommonName,
                    confidence: speciesConfidence ?? 0,
                    cnName: speciesCnName,
                    pinyin: speciesPinyin,
                    thresholdUsed: nil,
                    ebirdCode: nil
                )]
            }
            return []
        }
        set {
            if newValue.isEmpty {
                assignedSpeciesJSON = "[]"
                speciesScientificName = nil
                speciesCommonName = nil
                speciesCnName = nil
                speciesPinyin = nil
                speciesConfidence = nil
            } else {
                if let data = try? JSONEncoder().encode(newValue),
                   let json = String(data: data, encoding: .utf8) {
                    assignedSpeciesJSON = json
                } else {
                    assignedSpeciesJSON = "[]"
                }
                let primary = newValue[0]
                speciesScientificName = primary.scientificName
                speciesCommonName = primary.commonName
                speciesCnName = primary.cnName
                speciesPinyin = primary.pinyin
                speciesConfidence = primary.confidence
            }
        }
    }
}
