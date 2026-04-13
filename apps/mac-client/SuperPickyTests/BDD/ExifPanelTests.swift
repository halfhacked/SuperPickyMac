import Testing
import Foundation
import CoreGraphics
import ImageIO
@testable import SuperPicky

/// BDD tests for the EXIF floating panel feature.
/// Tests the data flow: image file → EXIFReader → EXIFData display.
@Suite struct ExifPanelTests {

    // MARK: - Helpers

    /// Creates a temp directory for test fixtures.
    func makeTempDir() throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// Creates a JPEG with full EXIF metadata and IPTC keywords injected.
    func createJPEGWithEXIF(at url: URL, make: String = "Nikon", model: String = "Z9",
                             lens: String = "NIKKOR Z 800mm f/6.3",
                             focalLength: Double = 800, aperture: Double = 6.3,
                             exposureTime: Double = 0.0005, iso: Int = 1600,
                             dateTime: String = "2025:03:15 07:30:22",
                             keywords: [String] = ["bird", "kingfisher", "wildlife"]) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 200, height: 150,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let image = context.makeImage()!

        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!

        let exifDict: [String: Any] = [
            kCGImagePropertyExifFNumber as String: aperture,
            kCGImagePropertyExifExposureTime as String: exposureTime,
            kCGImagePropertyExifISOSpeedRatings as String: [iso],
            kCGImagePropertyExifFocalLength as String: focalLength,
            kCGImagePropertyExifDateTimeOriginal as String: dateTime,
            kCGImagePropertyExifLensModel as String: lens,
        ]

        let tiffDict: [String: Any] = [
            kCGImagePropertyTIFFMake as String: make,
            kCGImagePropertyTIFFModel as String: model,
        ]

        let iptcDict: [String: Any] = [
            kCGImagePropertyIPTCKeywords as String: keywords,
        ]

        let properties: [String: Any] = [
            kCGImagePropertyExifDictionary as String: exifDict,
            kCGImagePropertyTIFFDictionary as String: tiffDict,
            kCGImagePropertyIPTCDictionary as String: iptcDict,
        ]

        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        CGImageDestinationFinalize(dest)
    }

    /// Creates a plain JPEG with no EXIF metadata.
    func createJPEGWithoutEXIF(at url: URL) {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 100, height: 100,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let image = context.makeImage()!
        let dest = CGImageDestinationCreateWithURL(url as CFURL, "public.jpeg" as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        CGImageDestinationFinalize(dest)
    }

    // MARK: - Scenario: EXIF panel reads full metadata from photo

    @Test func exifPanelShowsAllFieldsForPhotoWithFullEXIF() throws {
        let dir = try makeTempDir()
        let photoURL = dir.appendingPathComponent("bird_test.jpg")
        createJPEGWithEXIF(at: photoURL,
                           make: "Canon", model: "EOS R5",
                           lens: "RF 100-500mm F4.5-7.1 L IS USM",
                           focalLength: 500, aperture: 7.1,
                           exposureTime: 1.0 / 3200.0, iso: 3200,
                           dateTime: "2025:04:02 06:15:10",
                           keywords: ["bird", "eagle", "raptor"])

        let data = EXIFReader.read(from: photoURL.path)
        let exif = try #require(data)

        #expect(exif.cameraMake == "Canon")
        #expect(exif.cameraModel == "EOS R5")
        #expect(exif.lensModel == "RF 100-500mm F4.5-7.1 L IS USM")
        #expect(exif.focalLength == 500)
        #expect(exif.aperture == 7.1)
        #expect(exif.shutterSpeed == "1/3200")
        #expect(exif.iso == 3200)
        #expect(exif.dateTimeOriginal == "2025:04:02 06:15:10")
        #expect(exif.imageWidth == 200)
        #expect(exif.imageHeight == 150)
        #expect(!exif.isEmpty)
    }

    // MARK: - Scenario: EXIF panel shows IPTC keywords

    @Test func exifPanelShowsIPTCKeywords() throws {
        let dir = try makeTempDir()
        let photoURL = dir.appendingPathComponent("keywords_test.jpg")
        createJPEGWithEXIF(at: photoURL, keywords: ["bird", "kingfisher", "wildlife", "nature"])

        let data = EXIFReader.read(from: photoURL.path)
        let exif = try #require(data)

        #expect(exif.keywords == ["bird", "kingfisher", "wildlife", "nature"])
        #expect(exif.keywords.joined(separator: ", ") == "bird, kingfisher, wildlife, nature")
    }

    // MARK: - Scenario: EXIF panel shows empty keywords for photo without IPTC

    @Test func exifPanelShowsEmptyKeywordsWhenNoIPTC() throws {
        let dir = try makeTempDir()
        let photoURL = dir.appendingPathComponent("no_keywords.jpg")

        // Create JPEG with EXIF but no IPTC keywords
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let context = CGContext(
            data: nil, width: 100, height: 100,
            bitsPerComponent: 8, bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue
        )!
        let image = context.makeImage()!
        let dest = CGImageDestinationCreateWithURL(photoURL as CFURL, "public.jpeg" as CFString, 1, nil)!
        let exifDict: [String: Any] = [
            kCGImagePropertyExifFNumber as String: 4.0,
        ]
        let properties: [String: Any] = [
            kCGImagePropertyExifDictionary as String: exifDict,
        ]
        CGImageDestinationAddImage(dest, image, properties as CFDictionary)
        CGImageDestinationFinalize(dest)

        let data = EXIFReader.read(from: photoURL.path)
        let exif = try #require(data)

        #expect(exif.keywords.isEmpty)
        #expect(exif.aperture == 4.0) // EXIF still present
    }

    // MARK: - Scenario: EXIF panel shows fallback for photo without any metadata

    @Test func exifPanelShowsEmptyForPhotoWithoutEXIF() throws {
        let dir = try makeTempDir()
        let photoURL = dir.appendingPathComponent("plain.jpg")
        createJPEGWithoutEXIF(at: photoURL)

        let data = EXIFReader.read(from: photoURL.path)
        let exif = try #require(data)

        // All fields nil/empty — panel should show "No EXIF data available"
        #expect(exif.isEmpty)
        #expect(exif.cameraMake == nil)
        #expect(exif.keywords.isEmpty)
    }

    // MARK: - Scenario: EXIF panel handles non-existent file

    @Test func exifPanelReturnsNilForMissingFile() {
        let result = EXIFReader.read(from: "/nonexistent/photo.jpg")
        #expect(result == nil)
    }

    // MARK: - Scenario: EXIF panel updates when selection changes (data layer)

    @Test func exifDataDiffersPerPhoto() throws {
        let dir = try makeTempDir()
        let photo1URL = dir.appendingPathComponent("photo1.jpg")
        let photo2URL = dir.appendingPathComponent("photo2.jpg")

        createJPEGWithEXIF(at: photo1URL, make: "Nikon", model: "Z9", iso: 1600,
                           keywords: ["bird", "kingfisher"])
        createJPEGWithEXIF(at: photo2URL, make: "Canon", model: "EOS R5", iso: 3200,
                           keywords: ["bird", "eagle"])

        let data1 = try #require(EXIFReader.read(from: photo1URL.path))
        let data2 = try #require(EXIFReader.read(from: photo2URL.path))

        // Different photos produce different EXIF data
        #expect(data1.cameraMake == "Nikon")
        #expect(data2.cameraMake == "Canon")
        #expect(data1.iso == 1600)
        #expect(data2.iso == 3200)
        #expect(data1.keywords == ["bird", "kingfisher"])
        #expect(data2.keywords == ["bird", "eagle"])
    }

    // MARK: - Scenario: Shutter speed formatting

    @Test func shutterSpeedFormattedCorrectly() throws {
        let dir = try makeTempDir()

        // Fast shutter: 1/2000
        let fastURL = dir.appendingPathComponent("fast.jpg")
        createJPEGWithEXIF(at: fastURL, exposureTime: 1.0 / 2000.0)
        let fast = try #require(EXIFReader.read(from: fastURL.path))
        #expect(fast.shutterSpeed == "1/2000")

        // Slow shutter: 1s
        let slowURL = dir.appendingPathComponent("slow.jpg")
        createJPEGWithEXIF(at: slowURL, exposureTime: 1.0)
        let slow = try #require(EXIFReader.read(from: slowURL.path))
        #expect(slow.shutterSpeed == "1s")
    }

    // MARK: - Scenario: Read EXIF from real test-photos directory

    @Test func realTestPhotosHaveEXIFAndKeywords() throws {
        let testPhotosDir = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent() // BDD/
            .deletingLastPathComponent() // SuperPickyTests/
            .deletingLastPathComponent() // apps/mac-client/
            .deletingLastPathComponent() // apps/
            .deletingLastPathComponent() // project root
            .appendingPathComponent("test-photos")

        let kingfisher = testPhotosDir.appendingPathComponent("kingfisher_01.jpg")
        guard FileManager.default.fileExists(atPath: kingfisher.path) else {
            // Skip if test-photos not available (CI environment)
            return
        }

        let data = try #require(EXIFReader.read(from: kingfisher.path))
        #expect(data.cameraMake == "Nikon")
        #expect(data.cameraModel == "Z9")
        #expect(!data.keywords.isEmpty)
        #expect(data.keywords.contains("kingfisher"))
        #expect(data.keywords.contains("bird"))
        #expect(!data.isEmpty)
    }
}
