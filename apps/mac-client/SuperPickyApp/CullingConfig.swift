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

enum RawFormat: String, CaseIterable, Sendable {
    case cr2, cr3, nef, arw, raf, orf, rw2, pef, dng, iiq, hif, heif, heic
}

@Observable
final class CullingConfig {
    var sharpnessThreshold: Float { didSet { save() } }
    var aestheticsThreshold: Float { didSet { save() } }
    var eyeSharpnessThreshold: Float { didSet { save() } }
    var exposureDetectionEnabled: Bool { didSet { save() } }
    var exposureThreshold: Float { didSet { save() } }
    var burstDetectionEnabled: Bool { didSet { save() } }
    var namingStandard: NamingStandard { didSet { save() } }
    var backendPort: Int { didSet { save() } }
    var autoAdvance: Bool { didSet { save() } }
    var appLanguage: AppLanguage { didSet { save() } }
    var appTheme: AppTheme { didSet { save() } }
    var inferenceBackend: InferenceBackend { didSet { save() } }

    init() {
        let defaults = UserDefaults.standard
        self.sharpnessThreshold = defaults.object(forKey: "sharpnessThreshold") as? Float ?? 380
        self.aestheticsThreshold = defaults.object(forKey: "aestheticsThreshold") as? Float ?? 4.8
        self.eyeSharpnessThreshold = defaults.object(forKey: "eyeSharpnessThreshold") as? Float ?? 100
        self.exposureDetectionEnabled = defaults.object(forKey: "exposureDetectionEnabled") as? Bool ?? true
        self.exposureThreshold = defaults.object(forKey: "exposureThreshold") as? Float ?? 0.10
        self.burstDetectionEnabled = defaults.object(forKey: "burstDetectionEnabled") as? Bool ?? true
        self.namingStandard = NamingStandard(rawValue: defaults.string(forKey: "namingStandard") ?? "") ?? .osea
        self.backendPort = defaults.object(forKey: "backendPort") as? Int ?? 8420
        self.autoAdvance = defaults.object(forKey: "autoAdvance") as? Bool ?? false
        self.appLanguage = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .en
        self.appTheme = AppTheme(rawValue: defaults.string(forKey: "appTheme") ?? "") ?? .dark
        self.inferenceBackend = InferenceBackend(rawValue: defaults.string(forKey: "inferenceBackend") ?? "") ?? .http
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(sharpnessThreshold, forKey: "sharpnessThreshold")
        defaults.set(aestheticsThreshold, forKey: "aestheticsThreshold")
        defaults.set(eyeSharpnessThreshold, forKey: "eyeSharpnessThreshold")
        defaults.set(exposureDetectionEnabled, forKey: "exposureDetectionEnabled")
        defaults.set(exposureThreshold, forKey: "exposureThreshold")
        defaults.set(burstDetectionEnabled, forKey: "burstDetectionEnabled")
        defaults.set(namingStandard.rawValue, forKey: "namingStandard")
        defaults.set(backendPort, forKey: "backendPort")
        defaults.set(autoAdvance, forKey: "autoAdvance")
        defaults.set(appLanguage.rawValue, forKey: "appLanguage")
        defaults.set(appTheme.rawValue, forKey: "appTheme")
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
