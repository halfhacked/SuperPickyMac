import Foundation
import SwiftUI

enum SkillLevel: String, CaseIterable, Codable, Sendable {
    case beginner
    case intermediate
    case master

    var sharpnessThreshold: Float {
        switch self {
        case .beginner: 300
        case .intermediate: 380
        case .master: 520
        }
    }

    var aestheticsThreshold: Float {
        switch self {
        case .beginner: 4.5
        case .intermediate: 4.8
        case .master: 5.5
        }
    }
}

enum NamingStandard: String, CaseIterable, Codable, Sendable {
    case osea, avilist, clements, birdlife, scientific
}

enum ExposureStatus: String, Codable, Sendable {
    case normal, overexposed, underexposed
}

enum FocusPointStatus: String, Codable, Sendable {
    case onBird, offBird, notAvailable
}

enum RawFormat: String, CaseIterable, Sendable {
    case cr2, cr3, nef, arw, raf, orf, rw2, pef, dng, iiq, hif, heif, heic
}

@MainActor @Observable
final class CullingConfig {
    var skillLevel: SkillLevel {
        didSet {
            sharpnessThreshold = skillLevel.sharpnessThreshold
            aestheticsThreshold = skillLevel.aestheticsThreshold
            save()
        }
    }
    var sharpnessThreshold: Float { didSet { save() } }
    var aestheticsThreshold: Float { didSet { save() } }
    var exposureDetectionEnabled: Bool { didSet { save() } }
    var exposureThreshold: Float { didSet { save() } }
    var burstDetectionEnabled: Bool { didSet { save() } }
    var namingStandard: NamingStandard { didSet { save() } }
    var backendPort: Int { didSet { save() } }
    var writeKeywords: Bool { didSet { save() } }
    var keywordFormat: String { didSet { save() } }

    init() {
        let defaults = UserDefaults.standard
        let level = SkillLevel(rawValue: defaults.string(forKey: "skillLevel") ?? "") ?? .intermediate
        self.skillLevel = level
        self.sharpnessThreshold = defaults.object(forKey: "sharpnessThreshold") as? Float ?? level.sharpnessThreshold
        self.aestheticsThreshold = defaults.object(forKey: "aestheticsThreshold") as? Float ?? level.aestheticsThreshold
        self.exposureDetectionEnabled = defaults.object(forKey: "exposureDetectionEnabled") as? Bool ?? true
        self.exposureThreshold = defaults.object(forKey: "exposureThreshold") as? Float ?? 0.10
        self.burstDetectionEnabled = defaults.object(forKey: "burstDetectionEnabled") as? Bool ?? true
        self.namingStandard = NamingStandard(rawValue: defaults.string(forKey: "namingStandard") ?? "") ?? .osea
        self.backendPort = defaults.object(forKey: "backendPort") as? Int ?? 8420
        self.writeKeywords = defaults.object(forKey: "writeKeywords") as? Bool ?? true
        self.keywordFormat = defaults.string(forKey: "keywordFormat") ?? "{cn} {en} {pinyin}"
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(skillLevel.rawValue, forKey: "skillLevel")
        defaults.set(sharpnessThreshold, forKey: "sharpnessThreshold")
        defaults.set(aestheticsThreshold, forKey: "aestheticsThreshold")
        defaults.set(exposureDetectionEnabled, forKey: "exposureDetectionEnabled")
        defaults.set(exposureThreshold, forKey: "exposureThreshold")
        defaults.set(burstDetectionEnabled, forKey: "burstDetectionEnabled")
        defaults.set(namingStandard.rawValue, forKey: "namingStandard")
        defaults.set(backendPort, forKey: "backendPort")
        defaults.set(writeKeywords, forKey: "writeKeywords")
        defaults.set(keywordFormat, forKey: "keywordFormat")
    }
}
