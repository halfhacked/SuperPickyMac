import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import SuperPicky

@Suite struct EXIFReaderTests {

    // MARK: - Helpers

    /// Create a JPEG file at the given path with optional EXIF/TIFF/IPTC properties injected.
    private func createTestJPEG(
        at path: String,
        tiff: [String: Any]? = nil,
        exif: [String: Any]? = nil,
        exifAux: [String: Any]? = nil,
        iptc: [String: Any]? = nil,
        width: Int = 100,
        height: Int = 80
    ) {
        let url = URL(fileURLWithPath: path)
        let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
        let context = CGContext(
            data: nil, width: width, height: height,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        context.setFillColor(red: 0.5, green: 0.5, blue: 0.5, alpha: 1.0)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        let cgImage = context.makeImage()!

        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        var properties: [String: Any] = [:]
        if let tiff { properties[kCGImagePropertyTIFFDictionary as String] = tiff }
        if let exif { properties[kCGImagePropertyExifDictionary as String] = exif }
        if let exifAux { properties[kCGImagePropertyExifAuxDictionary as String] = exifAux }
        if let iptc { properties[kCGImagePropertyIPTCDictionary as String] = iptc }
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private func tempPath(_ name: String) -> String {
        NSTemporaryDirectory() + "EXIFReaderTests_\(name)"
    }

    // MARK: - Tests

    @Test func readReturnsNilForNonExistentFile() {
        let result = EXIFReader.read(from: "/tmp/nonexistent_\(UUID().uuidString).jpg")
        #expect(result == nil)
    }

    @Test func readReturnsEmptyFieldsForFileWithoutEXIF() {
        let path = tempPath("no_exif.jpg")
        defer { try? FileManager.default.removeItem(atPath: path) }
        createTestJPEG(at: path)

        let result = EXIFReader.read(from: path)
        #expect(result != nil)
        let data = result!
        #expect(data.cameraMake == nil)
        #expect(data.cameraModel == nil)
        #expect(data.lensModel == nil)
        #expect(data.focalLength == nil)
        #expect(data.aperture == nil)
        #expect(data.shutterSpeed == nil)
        #expect(data.iso == nil)
        #expect(data.dateTimeOriginal == nil)
        #expect(data.exposureBias == nil)
        #expect(data.meteringMode == nil)
        #expect(data.whiteBalance == nil)
        #expect(data.keywords.isEmpty)
        // Dimensions should still be readable from the image itself
        #expect(data.imageWidth == 100)
        #expect(data.imageHeight == 80)
    }

    @Test func readExtractsFullEXIFData() {
        let path = tempPath("full_exif.jpg")
        defer { try? FileManager.default.removeItem(atPath: path) }

        createTestJPEG(
            at: path,
            tiff: [
                kCGImagePropertyTIFFMake as String: "Canon",
                kCGImagePropertyTIFFModel as String: "EOS R5",
            ],
            exif: [
                kCGImagePropertyExifDateTimeOriginal as String: "2024:03:15 14:30:22",
                kCGImagePropertyExifFNumber as String: 2.8,
                kCGImagePropertyExifExposureTime as String: 0.002,
                kCGImagePropertyExifISOSpeedRatings as String: [800],
                kCGImagePropertyExifFocalLength as String: 200.0,
                kCGImagePropertyExifExposureBiasValue as String: -0.3,
                kCGImagePropertyExifMeteringMode as String: 5,
                kCGImagePropertyExifWhiteBalance as String: 0,
                kCGImagePropertyExifLensModel as String: "RF100-500mm F4.5-7.1 L IS USM",
            ],
            iptc: [
                kCGImagePropertyIPTCKeywords as String: ["Bird", "Eagle", "Wildlife"],
            ],
            width: 8192,
            height: 5464
        )

        let result = EXIFReader.read(from: path)
        #expect(result != nil)
        let data = result!
        #expect(data.cameraMake == "Canon")
        #expect(data.cameraModel == "EOS R5")
        #expect(data.lensModel == "RF100-500mm F4.5-7.1 L IS USM")
        #expect(data.focalLength == 200.0)
        #expect(data.aperture == 2.8)
        #expect(data.shutterSpeed == "1/500")
        #expect(data.iso == 800)
        #expect(data.dateTimeOriginal == "2024:03:15 14:30:22")
        #expect(data.imageWidth == 8192)
        #expect(data.imageHeight == 5464)
        #expect(data.exposureBias == -0.3)
        #expect(data.keywords == ["Bird", "Eagle", "Wildlife"])
    }

    @Test func readMergesKeywordsFromXMPSidecar() {
        let stem = "xmp_sidecar_\(UUID().uuidString)"
        let imagePath = NSTemporaryDirectory() + "EXIFReaderTests_\(stem).jpg"
        let sidecarPath = NSTemporaryDirectory() + "EXIFReaderTests_\(stem).xmp"
        defer {
            try? FileManager.default.removeItem(atPath: imagePath)
            try? FileManager.default.removeItem(atPath: sidecarPath)
        }
        createTestJPEG(
            at: imagePath,
            iptc: [kCGImagePropertyIPTCKeywords as String: ["Bird"]]
        )
        let xmp = """
            <?xml version="1.0" encoding="UTF-8"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/">
                  <dc:subject>
                    <rdf:Bag>
                      <rdf:li>Anna&apos;s Hummingbird</rdf:li>
                      <rdf:li>Calypte anna</rdf:li>
                      <rdf:li>安氏蜂鸟</rdf:li>
                      <rdf:li>Bird</rdf:li>
                    </rdf:Bag>
                  </dc:subject>
                </rdf:Description>
              </rdf:RDF>
            </x:xmpmeta>
            """
        try? xmp.write(toFile: sidecarPath, atomically: true, encoding: .utf8)

        let data = EXIFReader.read(from: imagePath)
        #expect(data != nil)
        // IPTC "Bird" first, then XMP items that aren't already in the list;
        // duplicate "Bird" from XMP is de-duped, and "&apos;" is unescaped.
        #expect(data!.keywords == [
            "Bird",
            "Anna's Hummingbird",
            "Calypte anna",
            "安氏蜂鸟",
        ])
    }

    @Test func readXMPKeywordsWhenImageHasNoIPTC() {
        let stem = "xmp_only_\(UUID().uuidString)"
        let imagePath = NSTemporaryDirectory() + "EXIFReaderTests_\(stem).jpg"
        let sidecarPath = NSTemporaryDirectory() + "EXIFReaderTests_\(stem).xmp"
        defer {
            try? FileManager.default.removeItem(atPath: imagePath)
            try? FileManager.default.removeItem(atPath: sidecarPath)
        }
        createTestJPEG(at: imagePath)
        let xmp = """
            <?xml version="1.0"?>
            <x:xmpmeta xmlns:x="adobe:ns:meta/">
              <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
                <rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/">
                  <dc:subject>
                    <rdf:Bag>
                      <rdf:li>Bald Eagle</rdf:li>
                    </rdf:Bag>
                  </dc:subject>
                </rdf:Description>
              </rdf:RDF>
            </x:xmpmeta>
            """
        try? xmp.write(toFile: sidecarPath, atomically: true, encoding: .utf8)

        let data = EXIFReader.read(from: imagePath)
        #expect(data?.keywords == ["Bald Eagle"])
    }

    @Test func shutterSpeedFormattingForLongExposure() {
        let path = tempPath("long_exposure.jpg")
        defer { try? FileManager.default.removeItem(atPath: path) }

        createTestJPEG(
            at: path,
            exif: [
                kCGImagePropertyExifExposureTime as String: 2.5,
            ]
        )

        let result = EXIFReader.read(from: path)
        #expect(result != nil)
        #expect(result!.shutterSpeed == "2.5s")
    }

    // MARK: - formatShutterSpeed (pure)

    @Test func formatShutterSpeedFractionalRoundsDenominator() {
        #expect(EXIFReader.formatShutterSpeed(1.0 / 2000) == "1/2000")
        #expect(EXIFReader.formatShutterSpeed(1.0 / 500) == "1/500")
        #expect(EXIFReader.formatShutterSpeed(0.0003) == "1/3333")
    }

    @Test func formatShutterSpeedWholeSecondsDropDecimal() {
        #expect(EXIFReader.formatShutterSpeed(1) == "1s")
        #expect(EXIFReader.formatShutterSpeed(30) == "30s")
    }

    @Test func formatShutterSpeedFractionalSecondsKeepDecimal() {
        #expect(EXIFReader.formatShutterSpeed(2.5) == "2.5s")
        #expect(EXIFReader.formatShutterSpeed(1.3) == "1.3s")
    }

    @Test func formatShutterSpeedOneSecondEdgeUsesSecondsForm() {
        #expect(EXIFReader.formatShutterSpeed(1.0) == "1s")
    }

    // MARK: - xmlUnescape (pure)

    @Test func xmlUnescapeReversesAllFiveEntities() {
        #expect(EXIFReader.xmlUnescape("&amp;") == "&")
        #expect(EXIFReader.xmlUnescape("&lt;") == "<")
        #expect(EXIFReader.xmlUnescape("&gt;") == ">")
        #expect(EXIFReader.xmlUnescape("&quot;") == "\"")
        #expect(EXIFReader.xmlUnescape("&apos;") == "'")
    }

    @Test func xmlUnescapeHandlesMixedAndRepeated() {
        #expect(EXIFReader.xmlUnescape("Tom &amp; Jerry &amp; Co") == "Tom & Jerry & Co")
        #expect(EXIFReader.xmlUnescape("&lt;tag&gt;") == "<tag>")
    }

    @Test func xmlUnescapeLeavesPlainStringUntouched() {
        #expect(EXIFReader.xmlUnescape("no entities here") == "no entities here")
        #expect(EXIFReader.xmlUnescape("") == "")
    }

    @Test func xmlUnescapeOrderProtectsAgainstDoubleDecode() {
        // "&amp;lt;" decodes to "&lt;" (one level), not "<".
        // Holds because `&amp;` is unescaped last.
        #expect(EXIFReader.xmlUnescape("&amp;lt;") == "&lt;")
    }

    // MARK: - describeMeteringMode (pure)

    @Test func describeMeteringModeKnownCodes() {
        #expect(EXIFReader.describeMeteringMode(1) == "Average")
        #expect(EXIFReader.describeMeteringMode(2) == "Center-weighted")
        #expect(EXIFReader.describeMeteringMode(3) == "Spot")
        #expect(EXIFReader.describeMeteringMode(4) == "Multi-spot")
        #expect(EXIFReader.describeMeteringMode(5) == "Multi-segment")
        #expect(EXIFReader.describeMeteringMode(6) == "Partial")
    }

    @Test func describeMeteringModeUnknownCodeFallsBack() {
        #expect(EXIFReader.describeMeteringMode(0) == "Unknown (0)")
        #expect(EXIFReader.describeMeteringMode(255) == "Unknown (255)")
        #expect(EXIFReader.describeMeteringMode(-1) == "Unknown (-1)")
    }

    @Test func describeMeteringModeNilIsNil() {
        #expect(EXIFReader.describeMeteringMode(nil) == nil)
    }

    // MARK: - parseXMPKeywords (pure)

    @Test func parseXMPKeywordsExtractsRdfLiEntries() {
        let xml = """
        <x:xmpmeta xmlns:x="adobe:ns:meta/">
          <rdf:RDF xmlns:rdf="http://www.w3.org/1999/02/22-rdf-syntax-ns#">
            <rdf:Description xmlns:dc="http://purl.org/dc/elements/1.1/">
              <dc:subject>
                <rdf:Bag>
                  <rdf:li>Bald Eagle</rdf:li>
                  <rdf:li>Haliaeetus leucocephalus</rdf:li>
                </rdf:Bag>
              </dc:subject>
            </rdf:Description>
          </rdf:RDF>
        </x:xmpmeta>
        """
        #expect(EXIFReader.parseXMPKeywords(xml: xml) == ["Bald Eagle", "Haliaeetus leucocephalus"])
    }

    @Test func parseXMPKeywordsEmptyWhenSubjectMissing() {
        let xml = "<?xml version=\"1.0\"?><root><other>stuff</other></root>"
        #expect(EXIFReader.parseXMPKeywords(xml: xml).isEmpty)
    }

    @Test func parseXMPKeywordsEmptyWhenCloseTagMissing() {
        // Opening <dc:subject> with no </dc:subject> is graceful: empty list.
        let xml = "<dc:subject><rdf:Bag><rdf:li>orphan</rdf:li></rdf:Bag>"
        #expect(EXIFReader.parseXMPKeywords(xml: xml).isEmpty)
    }

    @Test func parseXMPKeywordsIgnoresRdfLiOutsideSubjectBlock() {
        // A hierarchicalSubject block with rdf:li's should NOT leak into
        // the subject keywords result.
        let xml = """
        <rdf:RDF>
          <dc:subject>
            <rdf:Bag>
              <rdf:li>only this one</rdf:li>
            </rdf:Bag>
          </dc:subject>
          <lr:hierarchicalSubject>
            <rdf:Bag>
              <rdf:li>Bird|Eagle</rdf:li>
            </rdf:Bag>
          </lr:hierarchicalSubject>
        </rdf:RDF>
        """
        #expect(EXIFReader.parseXMPKeywords(xml: xml) == ["only this one"])
    }

    @Test func parseXMPKeywordsUnescapesEntities() {
        let xml = """
        <dc:subject>
          <rdf:Bag>
            <rdf:li>Tom &amp; Jerry</rdf:li>
            <rdf:li>&lt;tag&gt;</rdf:li>
          </rdf:Bag>
        </dc:subject>
        """
        #expect(EXIFReader.parseXMPKeywords(xml: xml) == ["Tom & Jerry", "<tag>"])
    }

    @Test func parseXMPKeywordsHandlesAttributedRdfLi() {
        // Some writers add attributes to rdf:li (xml:lang="x-default" etc).
        let xml = """
        <dc:subject>
          <rdf:Bag>
            <rdf:li xml:lang="x-default">With Lang</rdf:li>
          </rdf:Bag>
        </dc:subject>
        """
        #expect(EXIFReader.parseXMPKeywords(xml: xml) == ["With Lang"])
    }

    @Test func parseXMPKeywordsEmptyBagReturnsEmpty() {
        let xml = "<dc:subject><rdf:Bag></rdf:Bag></dc:subject>"
        #expect(EXIFReader.parseXMPKeywords(xml: xml).isEmpty)
    }
}
