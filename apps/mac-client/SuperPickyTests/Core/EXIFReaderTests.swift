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
}
