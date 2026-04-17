import Foundation
import Testing
import CoreGraphics
import ImageIO
import UniformTypeIdentifiers
@testable import SuperPickyInference

@Suite("GPSExtractor")
struct GPSExtractorTests {

    /// Write a 1x1 JPEG at `url` whose EXIF GPS IFD encodes the given
    /// latitude/longitude. `lat`/`lon` must be positive magnitudes; the
    /// sign is carried by `latRef` ("N"/"S") and `lonRef` ("E"/"W").
    private func writeFixture(
        to url: URL, lat: Double, lon: Double, latRef: String, lonRef: String
    ) throws {
        let w = 1, h = 1
        let bitmap = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = bitmap.makeImage()!
        let metadata: [CFString: Any] = [
            kCGImagePropertyGPSDictionary: [
                kCGImagePropertyGPSLatitude: lat,
                kCGImagePropertyGPSLatitudeRef: latRef,
                kCGImagePropertyGPSLongitude: lon,
                kCGImagePropertyGPSLongitudeRef: lonRef,
            ] as [CFString: Any]
        ]
        let dest = CGImageDestinationCreateWithURL(
            url as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(dest, image, metadata as CFDictionary)
        #expect(CGImageDestinationFinalize(dest))
    }

    @Test("Reads positive lat/lon from EXIF")
    func northernEastern() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gps-ne-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeFixture(to: tmp, lat: 44.5, lon: 123.0, latRef: "N", lonRef: "E")
        let gps = try #require(GPSExtractor.gps(for: tmp))
        #expect(abs(gps.lat - 44.5) < 0.001)
        #expect(abs(gps.lon - 123.0) < 0.001)
    }

    @Test("Applies S/W sign negation")
    func southernWestern() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gps-sw-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeFixture(to: tmp, lat: 33.8, lon: 151.2, latRef: "S", lonRef: "W")
        let gps = try #require(GPSExtractor.gps(for: tmp))
        #expect(abs(gps.lat - (-33.8)) < 0.001)
        #expect(abs(gps.lon - (-151.2)) < 0.001)
    }

    @Test("Returns nil when the file has no GPS IFD")
    func missingGPS() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("nogps-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: tmp) }
        // Write the fixture without metadata.
        let w = 1, h = 1
        let bitmap = CGContext(
            data: nil, width: w, height: h, bitsPerComponent: 8,
            bytesPerRow: 4, space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let image = bitmap.makeImage()!
        let dest = CGImageDestinationCreateWithURL(
            tmp as CFURL, UTType.jpeg.identifier as CFString, 1, nil
        )!
        CGImageDestinationAddImage(dest, image, nil)
        #expect(CGImageDestinationFinalize(dest))

        #expect(GPSExtractor.gps(for: tmp) == nil)
    }

    @Test("Rejects (0, 0) as unset")
    func zeroZeroRejected() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appendingPathComponent("gps-zero-\(UUID().uuidString).jpg")
        defer { try? FileManager.default.removeItem(at: tmp) }
        try writeFixture(to: tmp, lat: 0.0, lon: 0.0, latRef: "N", lonRef: "E")
        #expect(GPSExtractor.gps(for: tmp) == nil)
    }

    @Test("Returns nil for a non-existent path")
    func missingFile() {
        let missing = URL(fileURLWithPath: "/tmp/does-not-exist-\(UUID().uuidString).jpg")
        #expect(GPSExtractor.gps(for: missing) == nil)
    }

    // MARK: - gps(fromProperties:) overload

    @Test("fromProperties reads NE coords")
    func fromPropertiesNE() throws {
        let props: [String: Any] = [
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 47.6,
                kCGImagePropertyGPSLatitudeRef as String: "N",
                kCGImagePropertyGPSLongitude as String: 122.3,
                kCGImagePropertyGPSLongitudeRef as String: "E",
            ]
        ]
        let gps = try #require(GPSExtractor.gps(fromProperties: props))
        #expect(abs(gps.lat - 47.6) < 1e-4)
        #expect(abs(gps.lon - 122.3) < 1e-4)
    }

    @Test("fromProperties negates S/W refs")
    func fromPropertiesSW() throws {
        let props: [String: Any] = [
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 33.8,
                kCGImagePropertyGPSLatitudeRef as String: "S",
                kCGImagePropertyGPSLongitude as String: 151.2,
                kCGImagePropertyGPSLongitudeRef as String: "W",
            ]
        ]
        let gps = try #require(GPSExtractor.gps(fromProperties: props))
        #expect(abs(gps.lat - (-33.8)) < 1e-4)
        #expect(abs(gps.lon - (-151.2)) < 1e-4)
    }

    @Test("fromProperties returns nil with no GPS dict")
    func fromPropertiesNoDict() {
        let props: [String: Any] = [
            kCGImagePropertyPixelWidth as String: 100
        ]
        #expect(GPSExtractor.gps(fromProperties: props) == nil)
    }

    @Test("fromProperties rejects (0,0)")
    func fromPropertiesZeroZero() {
        let props: [String: Any] = [
            kCGImagePropertyGPSDictionary as String: [
                kCGImagePropertyGPSLatitude as String: 0.0,
                kCGImagePropertyGPSLongitude as String: 0.0,
            ]
        ]
        #expect(GPSExtractor.gps(fromProperties: props) == nil)
    }
}
