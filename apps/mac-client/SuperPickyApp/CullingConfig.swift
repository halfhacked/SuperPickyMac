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

enum SpeciesSortOrder: String, CaseIterable, Codable, Sendable {
    case name
    case count
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

@Observable
final class CullingConfig {
    var sharpnessThreshold: Float { didSet { save() } }
    var aestheticsThreshold: Float { didSet { save() } }
    var exposureDetectionEnabled: Bool { didSet { save() } }
    var exposureThreshold: Float { didSet { save() } }
    var burstDetectionEnabled: Bool { didSet { save() } }
    var namingStandard: NamingStandard { didSet { save() } }
    var autoAdvance: Bool { didSet { save() } }
    var appLanguage: AppLanguage { didSet { save() } }
    var appTheme: AppTheme { didSet { save() } }
    var minConfidence: Float { didSet { save() } }
    var minAesthetics: Float { didSet { save() } }
    var burstFps: Int { didSet { save() } }
    var burstMinCount: Int { didSet { save() } }
    /// Max pHash hamming distance (0–64) between consecutive frames still
    /// considered "same burst". Lower = stricter, more splits; higher =
    /// more tolerant of fast motion (e.g. wing-flap 20 fps hummingbirds).
    /// 12 matches imagehash's default; 20 is typical for fast subjects.
    var burstHashTolerance: Int { didSet { save() } }
    var birdIdConfidence: Int { didSet { save() } }
    var flightDetectionEnabled: Bool { didSet { save() } }
    var speciesSortOrder: SpeciesSortOrder { didSet { save() } }
    /// Whether to write JPEG sidecars under
    /// `~/Library/Caches/com.halfhacked.superpicky/preview/` to speed up
    /// zoom-mode keyboard navigation. Reads from existing cache files
    /// regardless.
    var generatePreviewCache: Bool { didSet { save(); applyPreviewCacheSettings() } }
    /// LRU cap on the preview-cache size. 0 means unlimited.
    var previewCacheSizeGB: Int { didSet { save(); applyPreviewCacheSettings() } }
    /// When enabled, ImageCache.fullRes uses 50 % of physical RAM instead
    /// of the default 25 %. Useful on Macs dedicated to SuperPicky; should
    /// be disabled when running other memory-hungry apps alongside.
    var aggressiveCache: Bool { didSet { save(); applyPreviewCacheSettings() } }

    init() {
        let defaults = UserDefaults.standard
        self.sharpnessThreshold = defaults.object(forKey: "sharpnessThreshold") as? Float ?? 380
        self.aestheticsThreshold = defaults.object(forKey: "aestheticsThreshold") as? Float ?? 4.8
        self.exposureDetectionEnabled = defaults.object(forKey: "exposureDetectionEnabled") as? Bool ?? true
        self.exposureThreshold = defaults.object(forKey: "exposureThreshold") as? Float ?? 0.10
        self.burstDetectionEnabled = defaults.object(forKey: "burstDetectionEnabled") as? Bool ?? true
        self.namingStandard = NamingStandard(rawValue: defaults.string(forKey: "namingStandard") ?? "") ?? .osea
        self.autoAdvance = defaults.object(forKey: "autoAdvance") as? Bool ?? false
        self.appLanguage = AppLanguage(rawValue: defaults.string(forKey: "appLanguage") ?? "") ?? .en
        self.appTheme = AppTheme(rawValue: defaults.string(forKey: "appTheme") ?? "") ?? .dark
        self.minConfidence = defaults.object(forKey: "minConfidence") as? Float ?? 0.5
        self.minAesthetics = defaults.object(forKey: "minAesthetics") as? Float ?? 3.5
        self.burstFps = defaults.object(forKey: "burstFps") as? Int ?? 10
        self.burstMinCount = defaults.object(forKey: "burstMinCount") as? Int ?? 4
        self.burstHashTolerance = defaults.object(forKey: "burstHashTolerance") as? Int ?? 12
        self.birdIdConfidence = defaults.object(forKey: "birdIdConfidence") as? Int ?? 70
        self.flightDetectionEnabled = defaults.object(forKey: "flightDetectionEnabled") as? Bool ?? true
        self.speciesSortOrder = SpeciesSortOrder(rawValue: defaults.string(forKey: "speciesSortOrder") ?? "") ?? .name
        self.generatePreviewCache = defaults.object(forKey: "generatePreviewCache") as? Bool ?? true
        self.previewCacheSizeGB = defaults.object(forKey: "previewCacheSizeGB") as? Int ?? 20
        self.aggressiveCache = defaults.object(forKey: "aggressiveCache") as? Bool ?? false
        applyPreviewCacheSettings()
    }

    /// Push the current preview-cache settings into the lock-guarded slot
    /// the decode path reads. Called from init and on every Settings change.
    /// Also re-sizes the in-memory `ImageCache.fullRes` to match the new
    /// aggressive-cache choice.
    private func applyPreviewCacheSettings() {
        let cap: Int64 = previewCacheSizeGB == 0
            ? 0
            : Int64(previewCacheSizeGB) * 1024 * 1024 * 1024
        let generate = generatePreviewCache
        let aggressive = aggressiveCache
        PreviewCache.updateSettings { s in
            s.generate = generate
            s.capBytes = cap
            s.aggressiveCache = aggressive
        }
        let budget = ImageCache.computeFullResBudget()
        ImageCache.fullRes.resize(countLimit: budget.count, byteLimit: budget.bytes)
    }

    private func save() {
        let defaults = UserDefaults.standard
        defaults.set(sharpnessThreshold, forKey: "sharpnessThreshold")
        defaults.set(aestheticsThreshold, forKey: "aestheticsThreshold")
        defaults.set(exposureDetectionEnabled, forKey: "exposureDetectionEnabled")
        defaults.set(exposureThreshold, forKey: "exposureThreshold")
        defaults.set(burstDetectionEnabled, forKey: "burstDetectionEnabled")
        defaults.set(namingStandard.rawValue, forKey: "namingStandard")
        defaults.set(autoAdvance, forKey: "autoAdvance")
        defaults.set(appLanguage.rawValue, forKey: "appLanguage")
        defaults.set(appTheme.rawValue, forKey: "appTheme")
        defaults.set(minConfidence, forKey: "minConfidence")
        defaults.set(minAesthetics, forKey: "minAesthetics")
        defaults.set(burstFps, forKey: "burstFps")
        defaults.set(burstMinCount, forKey: "burstMinCount")
        defaults.set(burstHashTolerance, forKey: "burstHashTolerance")
        defaults.set(birdIdConfidence, forKey: "birdIdConfidence")
        defaults.set(flightDetectionEnabled, forKey: "flightDetectionEnabled")
        defaults.set(speciesSortOrder.rawValue, forKey: "speciesSortOrder")
        defaults.set(generatePreviewCache, forKey: "generatePreviewCache")
        defaults.set(previewCacheSizeGB, forKey: "previewCacheSizeGB")
        defaults.set(aggressiveCache, forKey: "aggressiveCache")
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
