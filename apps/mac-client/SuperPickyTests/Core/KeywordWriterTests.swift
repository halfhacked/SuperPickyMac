import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import SuperPicky

@Suite struct KeywordWriterTests {

    // MARK: - Helpers

    private func createTestJPEG(
        at path: String,
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
        if let iptc { properties[kCGImagePropertyIPTCDictionary as String] = iptc }
        CGImageDestinationAddImage(dest, cgImage, properties as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    private func tempPath(_ name: String) -> String {
        NSTemporaryDirectory() + "KeywordWriterTests_\(name)"
    }


    // MARK: - Tests

    @Test func writeKeywordsToJPEG() throws {
        let path = tempPath("write_kw.jpg")
        defer { try? FileManager.default.removeItem(atPath: path) }
        createTestJPEG(at: path)

        try KeywordWriter.write(keywords: ["bird", "Eagle", "Wildlife"], to: path)

        let data = EXIFReader.read(from: path)
        #expect(data != nil)
        #expect(data!.keywords.contains("bird"))
        #expect(data!.keywords.contains("Eagle"))
        #expect(data!.keywords.contains("Wildlife"))
        #expect(data!.keywords.count == 3)
    }

    @Test func writeOverwritesExistingKeywords() throws {
        let path = tempPath("overwrite_kw.jpg")
        defer { try? FileManager.default.removeItem(atPath: path) }

        createTestJPEG(at: path)
        try KeywordWriter.write(keywords: ["bird", "Eagle"], to: path)

        // Second write overwrites (does not merge)
        try KeywordWriter.write(keywords: ["Eagle", "Wildlife"], to: path)

        let data = EXIFReader.read(from: path)
        #expect(data != nil)
        #expect(data!.keywords.contains("Eagle"))
        #expect(data!.keywords.contains("Wildlife"))
        #expect(data!.keywords.count == 2)
    }

    @Test func writeToNonexistentFileThrows() throws {
        let path = "/tmp/nonexistent_\(UUID().uuidString).jpg"
        #expect(throws: KeywordWriter.WriterError.fileNotFound) {
            try KeywordWriter.write(keywords: ["bird"], to: path)
        }
    }

    @Test func formatKeywordsFromTemplate() {
        let result = KeywordWriter.formatKeywords(
            template: "{cn} {en} {pinyin}",
            en: "Little Egret",
            cn: "白鹭",
            pinyin: "bailu"
        )
        #expect(result == ["白鹭", "Little Egret", "bailu"])
    }

    @Test func formatKeywordsSkipsNilTokens() {
        let result = KeywordWriter.formatKeywords(
            template: "{cn} {en} {pinyin}",
            en: "Little Egret",
            cn: nil,
            pinyin: nil
        )
        #expect(result == ["Little Egret"])
    }
}
