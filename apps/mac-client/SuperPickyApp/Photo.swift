import Foundation
import GRDB

struct Photo: Identifiable, Codable, Sendable, FetchableRecord, PersistableRecord {
    var id: UUID
    var filename: String
    var filePath: String
    var folderPath: String
    var dateCreated: Date
    var birdConfidence: Float?
    var birdBbox: Data?
    var birdMask: Data?
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
    var focusPointStatus: String?
    var starRating: Int
    var isPick: Bool
    var speciesScientificName: String?
    var speciesCommonName: String?
    var speciesConfidence: Float?
    var burstGroupID: UUID?
    var isBurstBest: Bool

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
    }
}
