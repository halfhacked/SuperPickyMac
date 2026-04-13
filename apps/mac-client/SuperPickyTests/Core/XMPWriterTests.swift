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

    // MARK: - Species with common name only (no scientific)

    @Test func xmpWithCommonNameOnly() {
        let photo = makePhoto(starRating: 3, speciesCommonName: "Robin")
        let xml = XMPWriter.generate(photo: photo)
        #expect(xml.contains("<rdf:li>Robin</rdf:li>"))
        #expect(xml.contains("<rdf:li>Bird|Robin</rdf:li>"))
        // No scientific name line beyond the common name
    }
}
