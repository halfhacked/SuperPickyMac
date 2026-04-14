import Testing
import Foundation
@testable import SuperPicky

@Suite(.serialized) @MainActor struct LocalizationTests {

    // MARK: - localizedName

    @Test func localizedNameEnglish() {
        let config = CullingConfig()
        config.appLanguage = .en
        #expect(config.localizedName(en: "Bald Eagle", cn: "白头海雕") == "Bald Eagle")
    }

    @Test func localizedNameChinese() {
        let config = CullingConfig()
        config.appLanguage = .zhHans
        #expect(config.localizedName(en: "Bald Eagle", cn: "白头海雕") == "白头海雕")
    }

    @Test func localizedNameChineseFallsBackToEnglish() {
        let config = CullingConfig()
        config.appLanguage = .zhHans
        #expect(config.localizedName(en: "Mystery Bird", cn: nil) == "Mystery Bird")
    }

    // MARK: - SpeciesEntry carries cnName

    @Test func speciesEntryCnName() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }

        let db = try ReportDatabase(folderPath: folder)
        var photo = Photo(filename: "a.jpg", filePath: folder.appendingPathComponent("a.jpg").path, folderPath: folder.path)
        photo.speciesCommonName = "Bald Eagle"
        photo.speciesScientificName = "Haliaeetus leucocephalus"
        photo.speciesCnName = "白头海雕"
        try db.save(&photo)

        let appState = AppState()
        appState.loadPhotos(for: folder)

        let entry = appState.speciesEntries.first { !$0.isUnidentified }!
        #expect(entry.name == "Bald Eagle")
        #expect(entry.cnName == "白头海雕")

        let config = CullingConfig()
        config.appLanguage = .en
        #expect(config.localizedName(en: entry.name, cn: entry.cnName) == "Bald Eagle")

        config.appLanguage = .zhHans
        #expect(config.localizedName(en: entry.name, cn: entry.cnName) == "白头海雕")
    }
}
