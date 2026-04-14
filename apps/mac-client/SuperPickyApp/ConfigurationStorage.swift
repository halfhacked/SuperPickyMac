import Foundation

/// Abstraction over the key/value store used to persist `CullingConfig`.
///
/// The protocol surface intentionally mirrors only the accessors that
/// `CullingConfig` needs today. When adding a new persisted property, extend
/// this protocol (and `UserDefaultsStorage`) rather than reaching for
/// `UserDefaults.standard` directly.
protocol ConfigurationStorage: AnyObject, Sendable {
    func bool(forKey key: String, default defaultValue: Bool) -> Bool
    func float(forKey key: String, default defaultValue: Float) -> Float
    func int(forKey key: String, default defaultValue: Int) -> Int
    func string(forKey key: String, default defaultValue: String) -> String

    func set(_ value: Bool, forKey key: String)
    func set(_ value: Float, forKey key: String)
    func set(_ value: Int, forKey key: String)
    func set(_ value: String, forKey key: String)
}

/// Default `ConfigurationStorage` backed by `UserDefaults`.
///
/// `UserDefaults` is documented as thread-safe but is not annotated
/// `Sendable`, so this conformance is `@unchecked`.
final class UserDefaultsStorage: ConfigurationStorage, @unchecked Sendable {
    private let defaults: UserDefaults

    init(_ defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func bool(forKey key: String, default defaultValue: Bool) -> Bool {
        defaults.object(forKey: key) as? Bool ?? defaultValue
    }

    func float(forKey key: String, default defaultValue: Float) -> Float {
        defaults.object(forKey: key) as? Float ?? defaultValue
    }

    func int(forKey key: String, default defaultValue: Int) -> Int {
        defaults.object(forKey: key) as? Int ?? defaultValue
    }

    func string(forKey key: String, default defaultValue: String) -> String {
        defaults.string(forKey: key) ?? defaultValue
    }

    func set(_ value: Bool, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func set(_ value: Float, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func set(_ value: Int, forKey key: String) {
        defaults.set(value, forKey: key)
    }

    func set(_ value: String, forKey key: String) {
        defaults.set(value, forKey: key)
    }
}
