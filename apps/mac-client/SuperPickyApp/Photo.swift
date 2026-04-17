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
    }

    var hasSpecies: Bool {
        speciesCommonName != nil || speciesScientificName != nil
    }
}
