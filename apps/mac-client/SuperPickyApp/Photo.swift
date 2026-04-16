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
    var eyeSharpnessScore: Float?
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
}
