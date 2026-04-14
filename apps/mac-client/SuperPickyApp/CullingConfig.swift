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

enum AppTheme: String, CaseIterable, Codable, Sendable {
    case system
    case dark
    case light

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .dark: .dark
        case .light: .light
        }
    }
}

enum RawFormat: String, CaseIterable, Sendable {
    case cr2, cr3, nef, arw, raf, orf, rw2, pef, dng, iiq, hif, heif, heic
}

@MainActor @Observable
final class CullingConfig {
    @ObservationIgnored private let storage: ConfigurationStorage

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
    var appTheme: AppTheme { didSet { save() } }

    init(storage: ConfigurationStorage = UserDefaultsStorage()) {
        self.storage = storage
        let level = SkillLevel(rawValue: storage.string(forKey: "skillLevel", default: "")) ?? .intermediate
        self.skillLevel = level
        self.sharpnessThreshold = storage.float(forKey: "sharpnessThreshold", default: level.sharpnessThreshold)
        self.aestheticsThreshold = storage.float(forKey: "aestheticsThreshold", default: level.aestheticsThreshold)
        self.exposureDetectionEnabled = storage.bool(forKey: "exposureDetectionEnabled", default: true)
        self.exposureThreshold = storage.float(forKey: "exposureThreshold", default: 0.10)
        self.burstDetectionEnabled = storage.bool(forKey: "burstDetectionEnabled", default: true)
        self.namingStandard = NamingStandard(rawValue: storage.string(forKey: "namingStandard", default: "")) ?? .osea
        self.backendPort = storage.int(forKey: "backendPort", default: 8420)
        self.writeKeywords = storage.bool(forKey: "writeKeywords", default: true)
        self.keywordFormat = storage.string(forKey: "keywordFormat", default: "{cn} {en} {pinyin}")
        self.appTheme = AppTheme(rawValue: storage.string(forKey: "appTheme", default: "")) ?? .dark
    }

    private func save() {
        storage.set(skillLevel.rawValue, forKey: "skillLevel")
        storage.set(sharpnessThreshold, forKey: "sharpnessThreshold")
        storage.set(aestheticsThreshold, forKey: "aestheticsThreshold")
        storage.set(exposureDetectionEnabled, forKey: "exposureDetectionEnabled")
        storage.set(exposureThreshold, forKey: "exposureThreshold")
        storage.set(burstDetectionEnabled, forKey: "burstDetectionEnabled")
        storage.set(namingStandard.rawValue, forKey: "namingStandard")
        storage.set(backendPort, forKey: "backendPort")
        storage.set(writeKeywords, forKey: "writeKeywords")
        storage.set(keywordFormat, forKey: "keywordFormat")
        storage.set(appTheme.rawValue, forKey: "appTheme")
    }
}
