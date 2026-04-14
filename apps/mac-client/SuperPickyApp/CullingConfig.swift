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

enum RawFormat: String, CaseIterable, Sendable {
    case cr2, cr3, nef, arw, raf, orf, rw2, pef, dng, iiq, hif, heif, heic
}

@Observable
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
    var autoAdvance: Bool { didSet { save() } }
    var appLanguage: AppLanguage { didSet { save() } }
    var appTheme: AppTheme { didSet { save() } }

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
        self.autoAdvance = defaults.object(forKey: "autoAdvance") as? Bool ?? false
        self.appLanguage = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .en
        self.appTheme = AppTheme(rawValue: defaults.string(forKey: "appTheme") ?? "") ?? .dark
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
        defaults.set(autoAdvance, forKey: "autoAdvance")
        defaults.set(appLanguage.rawValue, forKey: "appLanguage")
        defaults.set(appTheme.rawValue, forKey: "appTheme")
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
