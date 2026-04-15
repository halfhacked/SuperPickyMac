import Foundation
import SwiftUI

enum NamingStandard: String, CaseIterable, Codable, Sendable {
    case osea, avilist, clements, birdlife, scientific
}

enum ExposureStatus: String, Codable, Sendable {
    case normal, overexposed, underexposed
}

enum AppLanguage: String, CaseIterable, Codable, Sendable {
    case en
    case zhHans = "zh-Hans"

    var displayName: String {
        switch self {
        case .en: "English"
        case .zhHans: "中文（简体）"
        }
    }

    var locale: Locale {
        switch self {
        case .en: Locale(identifier: "en")
        case .zhHans: Locale(identifier: "zh-Hans")
        }
    }
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

enum SkillLevel: String, CaseIterable, Codable, Sendable {
    case beginner, intermediate, master, custom

    /// Preset sharpness threshold, or nil for custom (user controls manually).
    var sharpnessThreshold: Float? {
        switch self {
        case .beginner: 300
        case .intermediate: 380
        case .master: 520
        case .custom: nil
        }
    }

    /// Preset aesthetics threshold, or nil for custom (user controls manually).
    var aestheticsThreshold: Float? {
        switch self {
        case .beginner: 4.5
        case .intermediate: 4.8
        case .master: 5.5
        case .custom: nil
        }
    }
}

enum RawFormat: String, CaseIterable, Sendable {
    case cr2, cr3, nef, arw, raf, orf, rw2, pef, dng, iiq, hif, heif, heic
}

@Observable
final class CullingConfig {
    var sharpnessThreshold: Float { didSet { save() } }
    var aestheticsThreshold: Float { didSet { save() } }
    var exposureDetectionEnabled: Bool { didSet { save() } }
    var exposureThreshold: Float { didSet { save() } }
    var burstDetectionEnabled: Bool { didSet { save() } }
    var namingStandard: NamingStandard { didSet { save() } }
    var backendPort: Int { didSet { save() } }
    var autoAdvance: Bool { didSet { save() } }
    var appLanguage: AppLanguage { didSet { save() } }
    var appTheme: AppTheme { didSet { save() } }
    var skillLevel: SkillLevel { didSet { save() } }
    var minConfidence: Float { didSet { save() } }
    var minAesthetics: Float { didSet { save() } }
    var pickedTopPercentage: Int { didSet { save() } }
    var burstFps: Int { didSet { save() } }
    var burstMinCount: Int { didSet { save() } }
    var birdIdConfidence: Int { didSet { save() } }
    var flightDetectionEnabled: Bool { didSet { save() } }
    var inferenceBackend: InferenceBackend { didSet { save() } }

    init() {
        let defaults = UserDefaults.standard
        self.sharpnessThreshold = defaults.object(forKey: "sharpnessThreshold") as? Float ?? 380
        self.aestheticsThreshold = defaults.object(forKey: "aestheticsThreshold") as? Float ?? 4.8
        self.exposureDetectionEnabled = defaults.object(forKey: "exposureDetectionEnabled") as? Bool ?? true
        self.exposureThreshold = defaults.object(forKey: "exposureThreshold") as? Float ?? 0.10
        self.burstDetectionEnabled = defaults.object(forKey: "burstDetectionEnabled") as? Bool ?? true
        self.namingStandard = NamingStandard(rawValue: defaults.string(forKey: "namingStandard") ?? "") ?? .osea
        self.backendPort = defaults.object(forKey: "backendPort") as? Int ?? 8420
        self.autoAdvance = defaults.object(forKey: "autoAdvance") as? Bool ?? false
        self.appLanguage = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .en
        self.appTheme = AppTheme(rawValue: defaults.string(forKey: "appTheme") ?? "") ?? .dark
        self.skillLevel = SkillLevel(rawValue: defaults.string(forKey: "skillLevel") ?? "") ?? .intermediate
        self.minConfidence = defaults.object(forKey: "minConfidence") as? Float ?? 0.5
        self.minAesthetics = defaults.object(forKey: "minAesthetics") as? Float ?? 3.5
        self.pickedTopPercentage = defaults.object(forKey: "pickedTopPercentage") as? Int ?? 25
        self.burstFps = defaults.object(forKey: "burstFps") as? Int ?? 10
        self.burstMinCount = defaults.object(forKey: "burstMinCount") as? Int ?? 4
        self.birdIdConfidence = defaults.object(forKey: "birdIdConfidence") as? Int ?? 70
        self.flightDetectionEnabled = defaults.object(forKey: "flightDetectionEnabled") as? Bool ?? true
        self.inferenceBackend = InferenceBackend(rawValue: defaults.string(forKey: "inferenceBackend") ?? "") ?? .native
    }

    /// Apply a skill level preset. For beginner/intermediate/master, updates thresholds.
    /// For custom, preserves current thresholds.
    func applySkillLevel(_ level: SkillLevel) {
        skillLevel = level
        if let sharpness = level.sharpnessThreshold {
            sharpnessThreshold = sharpness
        }
        if let aesthetics = level.aestheticsThreshold {
            aestheticsThreshold = aesthetics
        }
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(sharpnessThreshold, forKey: "sharpnessThreshold")
        defaults.set(aestheticsThreshold, forKey: "aestheticsThreshold")
        defaults.set(exposureDetectionEnabled, forKey: "exposureDetectionEnabled")
        defaults.set(exposureThreshold, forKey: "exposureThreshold")
        defaults.set(burstDetectionEnabled, forKey: "burstDetectionEnabled")
        defaults.set(namingStandard.rawValue, forKey: "namingStandard")
        defaults.set(backendPort, forKey: "backendPort")
        defaults.set(autoAdvance, forKey: "autoAdvance")
        defaults.set(appLanguage.rawValue, forKey: "appLanguage")
        defaults.set(appTheme.rawValue, forKey: "appTheme")
        defaults.set(skillLevel.rawValue, forKey: "skillLevel")
        defaults.set(minConfidence, forKey: "minConfidence")
        defaults.set(minAesthetics, forKey: "minAesthetics")
        defaults.set(pickedTopPercentage, forKey: "pickedTopPercentage")
        defaults.set(burstFps, forKey: "burstFps")
        defaults.set(burstMinCount, forKey: "burstMinCount")
        defaults.set(birdIdConfidence, forKey: "birdIdConfidence")
        defaults.set(flightDetectionEnabled, forKey: "flightDetectionEnabled")
        defaults.set(inferenceBackend.rawValue, forKey: "inferenceBackend")
    }

    /// Look up a localized string. Reading `appLanguage` makes SwiftUI
    /// re-render views that call this when the language changes.
    func localized(_ key: String) -> String {
        LocalizationManager.string(key, language: appLanguage)
    }

    /// Whether the effective language prefers Chinese names.
    var prefersChinese: Bool { appLanguage == .zhHans }

    /// Pick the correct name given an English name and optional Chinese name.
    func localizedName(en: String, cn: String?) -> String {
        if prefersChinese, let cn { return cn }
        return en
    }
}
