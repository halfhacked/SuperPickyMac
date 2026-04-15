import Foundation
import Testing
@testable import SuperPicky

@Suite("InferenceBackendSetting", .serialized) @MainActor
struct InferenceBackendSettingTests {
    @Test("Enum has http and native cases")
    func cases() {
        #expect(InferenceBackend.allCases.count == 2)
        #expect(InferenceBackend.allCases.contains(.http))
        #expect(InferenceBackend.allCases.contains(.native))
    }

    @Test("Raw values are stable strings")
    func rawValues() {
        #expect(InferenceBackend.http.rawValue == "http")
        #expect(InferenceBackend.native.rawValue == "native")
    }

    @Test("CullingConfig defaults inferenceBackend to .native")
    func defaultsToNative() {
        UserDefaults.standard.removeObject(forKey: "inferenceBackend")
        let config = CullingConfig()
        #expect(config.inferenceBackend == .native)
    }

    @Test("CullingConfig.inferenceBackend persists to UserDefaults")
    func persistence() {
        UserDefaults.standard.removeObject(forKey: "inferenceBackend")
        let config = CullingConfig()
        config.inferenceBackend = .native
        #expect(UserDefaults.standard.string(forKey: "inferenceBackend") == "native")

        let config2 = CullingConfig()
        #expect(config2.inferenceBackend == .native)

        UserDefaults.standard.removeObject(forKey: "inferenceBackend")
    }
}
