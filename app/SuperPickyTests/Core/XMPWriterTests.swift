import Testing
import Foundation
@testable import SuperPicky

@Suite struct XMPWriterTests {

    // MARK: - Helper

    private func makePhoto(
        filename: String = "IMG_1234.CR3",
        filePath: String = "/path/to/IMG_1234.CR3",
        starRating: Int = 0,
        speciesCommonName: String? = nil,
        speciesScientificName: String? = nil,
        speciesCnName: String? = nil,
        speciesPinyin: String? = nil,
        isFlying: Bool = false
    ) -> Photo {
        var photo = Photo(
            filename: filename,
            filePath: filePath,
            folderPath: "/path/to"
        )
        photo.starRating = starRating
        photo.speciesCommonName = speciesCommonName
        photo.speciesScientificName = speciesScientificName
        photo.speciesCnName = speciesCnName
        photo.speciesPinyin = speciesPinyin
        photo.isFlying = isFlying
        return photo
    }

    // MARK: - Rating

    @Test func xmpContainsRating() {
        let photo = makePhoto(starRating: 4, speciesCommonName: "Bald Eagle",
                              speciesScientificName: "Haliaeetus leucocephalus")
        let xml = XMPWriter.generate(photo: photo)
        #expect(xml.contains("xmp:Rating=\"4\""))
    }

    // MARK: - Pick status

    @Test func xmpContainsPickStatusForPicked() {
        var photo = makePhoto(starRating: 5)
        photo.isPick = true
        let xml = XMPWriter.generate(photo: photo)
        #expect(xml.contains("xmp:PickStatus=\"1\""))
    }

    @Test func xmpContainsPickStatusZeroForUnpicked() {
        let photo = makePhoto(starRating: 3)
        let xml = XMPWriter.generate(photo: photo)
        #expect(xml.contains("xmp:PickStatus=\"0\""))
    }

    // MARK: - Species keywords

    @Test func xmpContainsSpeciesKeywords() {
        let photo = makePhoto(starRating: 4, speciesCommonName: "Bald Eagle",
                              speciesScientificName: "Haliaeetus leucocephalus")
        let xml = XMPWriter.generate(photo: photo)
        #expect(xml.contains("<rdf:li>Bald Eagle</rdf:li>"))
        #expect(xml.contains("<rdf:li>Haliaeetus leucocephalus</rdf:li>"))
        #expect(xml.contains("<rdf:li>Bird|Bald Eagle</rdf:li>"))
    }

    // MARK: - Flight tag

    @Test func xmpContainsFlightTag() {
        let photo = makePhoto(starRating: 3, isFlying: true)
        let xml = XMPWriter.generate(photo: photo)
        #expect(xml.contains("<rdf:li>In Flight</rdf:li>"))
        #expect(xml.contains("<rdf:li>Behavior|In Flight</rdf:li>"))
    }

    // MARK: - Rating only (no species, no flight)

    @Test func xmpRatingOnlyNoKeywordSections() {
        let photo = makePhoto(starRating: 2)
        let xml = XMPWriter.generate(photo: photo)
        #expect(xml.contains("xmp:Rating=\"2\""))
        #expect(!xml.contains("dc:subject"))
        #expect(!xml.contains("lr:hierarchicalSubject"))
    }

    // MARK: - XML escaping

    @Test func xmlEscapesSpecialCharacters() {
        let photo = makePhoto(starRating: 3, speciesCommonName: "Black & White Warbler",
                              speciesScientificName: "Mniotilta varia")
        let xml = XMPWriter.generate(photo: photo)
        #expect(xml.contains("<rdf:li>Black &amp; White Warbler</rdf:li>"))
        #expect(!xml.contains("<rdf:li>Black & White Warbler</rdf:li>"))
        #expect(xml.contains("<rdf:li>Bird|Black &amp; White Warbler</rdf:li>"))
    }

    // MARK: - Sidecar URL

    @Test func sidecarURLReplacesExtension() {
        let photo = makePhoto(filename: "IMG_1234.CR3", filePath: "/path/to/IMG_1234.CR3")
        let url = XMPWriter.sidecarURL(for: photo)
        #expect(url.path.hasSuffix("/IMG_1234.xmp"))
        #expect(url.path == "/path/to/IMG_1234.xmp")
    }

    // MARK: - Write to disk

    @Test func writeToDisk() throws {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let filePath = tempDir.appendingPathComponent("IMG_5678.CR3").path
        let photo = makePhoto(
            filename: "IMG_5678.CR3",
            filePath: filePath,
            starRating: 5,
            speciesCommonName: "Peregrine Falcon",
            speciesScientificName: "Falco peregrinus",
            isFlying: true
        )

        let sidecarURL = try XMPWriter.write(photo: photo)
        #expect(FileManager.default.fileExists(atPath: sidecarURL.path))

        let content = try String(contentsOf: sidecarURL, encoding: .utf8)
        #expect(content.contains("xmp:Rating=\"5\""))
        #expect(content.contains("<rdf:li>Peregrine Falcon</rdf:li>"))
        #expect(content.contains("<rdf:li>Falco peregrinus</rdf:li>"))
        #expect(content.contains("<rdf:li>In Flight</rdf:li>"))
        #expect(content.contains("<rdf:li>Bird|Peregrine Falcon</rdf:li>"))
        #expect(content.contains("<rdf:li>Behavior|In Flight</rdf:li>"))
    }

    // MARK: - Valid XML structure

    @Test func generatedXMLHasValidStructure() {
        let photo = makePhoto(starRating: 3, speciesCommonName: "Robin")
        let xml = XMPWriter.generate(photo: photo)
        #expect(xml.hasPrefix("<?xml version=\"1.0\" encoding=\"UTF-8\"?>"))
        #expect(xml.contains("<x:xmpmeta xmlns:x=\"adobe:ns:meta/\">"))
        #expect(xml.contains("</x:xmpmeta>"))
    }

    // MARK: - Chinese name and pinyin

    @Test func xmpContainsCnNameAndPinyin() {
        let photo = makePhoto(starRating: 4, speciesCommonName: "Common Kingfisher",
                              speciesScientificName: "Alcedo atthis",
                              speciesCnName: "普通翠鸟", speciesPinyin: "putongtsuiniao")
        let xml = XMPWriter.generate(photo: photo)
        #expect(xml.contains("<rdf:li>普通翠鸟</rdf:li>"))
        #expect(xml.contains("<rdf:li>putongtsuiniao</rdf:li>"))
    }

    @Test func xmpOmitsNilCnNameAndPinyin() {
        let photo = makePhoto(starRating: 4, speciesCommonName: "Bald Eagle",
                              speciesScientificName: "Haliaeetus leucocephalus")
        let xml = XMPWriter.generate(photo: photo)
        #expect(xml.contains("<rdf:li>Bald Eagle</rdf:li>"))
        // Should not have extra empty tags
        let liCount = xml.components(separatedBy: "<rdf:li>").count - 1
        #expect(liCount == 3) // common + scientific + hierarchical Bird|common
    }

    @Test func xmpWithCnNameOnly() {
        let photo = makePhoto(starRating: 3, speciesCnName: "普通翠鸟")
        let xml = XMPWriter.generate(photo: photo)
        #expect(xml.contains("<rdf:li>普通翠鸟</rdf:li>"))
        #expect(xml.contains("dc:subject"))
    }

    // MARK: - Species with common name only (no scientific)

    @Test func xmpWithCommonNameOnly() {
        let photo = makePhoto(starRating: 3, speciesCommonName: "Robin")
        let xml = XMPWriter.generate(photo: photo)
        #expect(xml.contains("<rdf:li>Robin</rdf:li>"))
        #expect(xml.contains("<rdf:li>Bird|Robin</rdf:li>"))
        // No scientific name line beyond the common name
    }

    // MARK: - Multi-species

    @Test func xmpEmitsKeywordsForEveryAssignedSpecies() {
        var photo = makePhoto(starRating: 4, isFlying: false)
        photo.assignedSpecies = [
            SpeciesMatch(scientificName: "Aquila chrysaetos", commonName: "Golden Eagle",
                         confidence: 0.9, cnName: "金雕", pinyin: "jindiao",
                         thresholdUsed: "gps", ebirdCode: "goleag"),
            SpeciesMatch(scientificName: "Buteo jamaicensis", commonName: "Red-tailed Hawk",
                         confidence: 0.4, cnName: nil, pinyin: nil,
                         thresholdUsed: "country", ebirdCode: "rethaw"),
        ]
        let xml = XMPWriter.generate(photo: photo)
        #expect(xml.contains("<rdf:li>Golden Eagle</rdf:li>"))
        #expect(xml.contains("<rdf:li>Aquila chrysaetos</rdf:li>"))
        #expect(xml.contains("<rdf:li>金雕</rdf:li>"))
        #expect(xml.contains("<rdf:li>jindiao</rdf:li>"))
        #expect(xml.contains("<rdf:li>Red-tailed Hawk</rdf:li>"))
        #expect(xml.contains("<rdf:li>Buteo jamaicensis</rdf:li>"))
        #expect(xml.contains("<rdf:li>Bird|Golden Eagle</rdf:li>"))
        #expect(xml.contains("<rdf:li>Bird|Red-tailed Hawk</rdf:li>"))
    }

    @Test func xmpMultipleSpeciesPlusFlyingEmitsAllKeywords() {
        var photo = makePhoto(starRating: 4, isFlying: true)
        photo.assignedSpecies = [
            SpeciesMatch(scientificName: "A", commonName: "First",
                         confidence: 0.9, cnName: nil, pinyin: nil,
                         thresholdUsed: "gps", ebirdCode: "a"),
            SpeciesMatch(scientificName: "B", commonName: "Second",
                         confidence: 0.5, cnName: nil, pinyin: nil,
                         thresholdUsed: "country", ebirdCode: "b"),
        ]
        let xml = XMPWriter.generate(photo: photo)
        #expect(xml.contains("<rdf:li>First</rdf:li>"))
        #expect(xml.contains("<rdf:li>Second</rdf:li>"))
        #expect(xml.contains("<rdf:li>In Flight</rdf:li>"))
        #expect(xml.contains("<rdf:li>Bird|First</rdf:li>"))
        #expect(xml.contains("<rdf:li>Bird|Second</rdf:li>"))
        #expect(xml.contains("<rdf:li>Behavior|In Flight</rdf:li>"))
    }

    @Test func xmpEmptyAssignedListWithFlyingStillEmitsFlightKeyword() {
        var photo = makePhoto(starRating: 3, isFlying: true)
        photo.assignedSpecies = []
        let xml = XMPWriter.generate(photo: photo)
        // Flight section present even when the photo has no species.
        #expect(xml.contains("dc:subject"))
        #expect(xml.contains("<rdf:li>In Flight</rdf:li>"))
        #expect(xml.contains("<rdf:li>Behavior|In Flight</rdf:li>"))
    }

    @Test func xmpEmptyAssignedListAndNotFlyingOmitsKeywordSections() {
        var photo = makePhoto(starRating: 2)
        photo.assignedSpecies = []
        let xml = XMPWriter.generate(photo: photo)
        #expect(!xml.contains("dc:subject"))
        #expect(!xml.contains("lr:hierarchicalSubject"))
    }

    @Test func xmpDedupesKeywordsThatCollideAcrossSpecies() {
        // Two matches sharing the same common name — rare but possible for
        // renamed OSEA classes. Only one rdf:li per unique string.
        var photo = makePhoto(starRating: 3)
        photo.assignedSpecies = [
            SpeciesMatch(scientificName: "Species A", commonName: "Sparrow",
                         confidence: 0.8, cnName: nil, pinyin: nil,
                         thresholdUsed: "global", ebirdCode: "a"),
            SpeciesMatch(scientificName: "Species B", commonName: "Sparrow",
                         confidence: 0.3, cnName: nil, pinyin: nil,
                         thresholdUsed: "global", ebirdCode: "b"),
        ]
        let xml = XMPWriter.generate(photo: photo)
        let sparrowCount = xml.components(separatedBy: "<rdf:li>Sparrow</rdf:li>").count - 1
        #expect(sparrowCount == 1)
        // Hierarchy also dedupes
        let hierCount = xml.components(separatedBy: "<rdf:li>Bird|Sparrow</rdf:li>").count - 1
        #expect(hierCount == 1)
    }

    // MARK: - Pure-helper tests: keywordBag / hierarchicalBag

    private func match(_ ebird: String, common: String? = nil, scientific: String? = nil,
                       cn: String? = nil, pinyin: String? = nil,
                       pinyinInitials: String? = nil) -> SpeciesMatch {
        SpeciesMatch(
            scientificName: scientific ?? "Genus \(ebird)",
            commonName: common,
            confidence: 0.5,
            cnName: cn,
            pinyin: pinyin,
            pinyinInitials: pinyinInitials,
            thresholdUsed: nil,
            ebirdCode: ebird
        )
    }

    @Test func keywordBagEmitsCommonScientificCnPinyinInOrder() {
        let bag = XMPWriter.keywordBag(for: [
            match("baleag", common: "Bald Eagle",
                  scientific: "Haliaeetus leucocephalus",
                  cn: "白头海雕", pinyin: "baitouhaidiao", pinyinInitials: "btHd"),
        ], isFlying: false)
        #expect(bag == ["Bald Eagle", "Haliaeetus leucocephalus", "白头海雕", "baitouhaidiao", "btHd"])
    }

    @Test func keywordBagEmitsPinyinWithoutInitialsWhenInitialsMissing() {
        let bag = XMPWriter.keywordBag(for: [
            match("baleag", common: "Bald Eagle",
                  scientific: "Haliaeetus leucocephalus",
                  cn: "白头海雕", pinyin: "baitouhaidiao", pinyinInitials: nil),
        ], isFlying: false)
        #expect(bag == ["Bald Eagle", "Haliaeetus leucocephalus", "白头海雕", "baitouhaidiao"])
    }

    @Test func keywordBagOmitsInitialsWhenPinyinMissing() {
        // Initials without pinyin is semantically inconsistent — the data never
        // ships that way — but the writer should still suppress orphan initials
        // so the pinyin/initials pair never splits.
        let bag = XMPWriter.keywordBag(for: [
            match("baleag", common: "Bald Eagle",
                  scientific: "Haliaeetus leucocephalus",
                  cn: nil, pinyin: nil, pinyinInitials: "btHd"),
        ], isFlying: false)
        #expect(bag == ["Bald Eagle", "Haliaeetus leucocephalus"])
    }

    @Test func keywordBagSkipsNilFields() {
        let bag = XMPWriter.keywordBag(for: [
            match("baleag", common: "Bald Eagle",
                  scientific: "Haliaeetus leucocephalus",
                  cn: nil, pinyin: nil),
        ], isFlying: false)
        #expect(bag == ["Bald Eagle", "Haliaeetus leucocephalus"])
    }

    @Test func keywordBagAppendsFlightLast() {
        let bag = XMPWriter.keywordBag(for: [
            match("baleag", common: "Bald Eagle",
                  scientific: "Haliaeetus leucocephalus"),
        ], isFlying: true)
        #expect(bag.last == "In Flight")
    }

    @Test func keywordBagFlightOnlyWhenAssignedIsEmpty() {
        let bag = XMPWriter.keywordBag(for: [], isFlying: true)
        #expect(bag == ["In Flight"])
    }

    @Test func keywordBagEmptyInputEmptyOutput() {
        #expect(XMPWriter.keywordBag(for: [], isFlying: false).isEmpty)
    }

    @Test func keywordBagDedupesCollisionsAcrossSpecies() {
        let bag = XMPWriter.keywordBag(for: [
            match("a", common: "Sparrow", scientific: "Species A"),
            match("b", common: "Sparrow", scientific: "Species B"),
        ], isFlying: false)
        #expect(bag == ["Sparrow", "Species A", "Species B"])
    }

    @Test func keywordBagDedupesCnAcrossSpecies() {
        let bag = XMPWriter.keywordBag(for: [
            match("a", common: "Finch A", scientific: "X a", cn: "雀"),
            match("b", common: "Finch B", scientific: "X b", cn: "雀"),
        ], isFlying: false)
        // Both species emit but the shared cnName "雀" appears only once.
        #expect(bag.filter { $0 == "雀" }.count == 1)
    }

    @Test func hierarchicalBagPrefixesEveryCommonWithBird() {
        let bag = XMPWriter.hierarchicalBag(for: [
            match("a", common: "Bald Eagle"),
            match("b", common: "Golden Eagle"),
        ], isFlying: false)
        #expect(bag == ["Bird|Bald Eagle", "Bird|Golden Eagle"])
    }

    @Test func hierarchicalBagSkipsMatchesWithoutCommonName() {
        let bag = XMPWriter.hierarchicalBag(for: [
            match("a", common: nil),
            match("b", common: "Osprey"),
        ], isFlying: false)
        #expect(bag == ["Bird|Osprey"])
    }

    @Test func hierarchicalBagAppendsBehaviorInFlightLast() {
        let bag = XMPWriter.hierarchicalBag(for: [
            match("a", common: "Osprey"),
        ], isFlying: true)
        #expect(bag.last == "Behavior|In Flight")
    }

    @Test func hierarchicalBagDedupesByCommonNameOnly() {
        let bag = XMPWriter.hierarchicalBag(for: [
            match("a", common: "Sparrow", scientific: "Species A"),
            match("b", common: "Sparrow", scientific: "Species B"),
        ], isFlying: false)
        #expect(bag == ["Bird|Sparrow"])
    }

    @Test func hierarchicalBagEmptyWhenNoCommonNamesAndNotFlying() {
        let bag = XMPWriter.hierarchicalBag(for: [
            match("a", common: nil),
        ], isFlying: false)
        #expect(bag.isEmpty)
    }
}
